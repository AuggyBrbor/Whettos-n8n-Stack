#!/bin/bash
echo "PDF Merger sidecar initializing... (Using robust polling loop)"

# Define the *single* directory this script will watch for all triggers
WATCH_DIR="/data/triggers"
echo "Watching for triggers in $WATCH_DIR"

# --- MAIN LOOP ---
# This is a robust polling loop. It's more reliable in Docker
# than 'inotifywait' as it doesn't depend on filesystem events.
while true; do
  
  # Find all '.trigger' files in the watch directory
  # We use 'find' with '-maxdepth 1' to only search the top level
  find "$WATCH_DIR" -maxdepth 1 -type f -name "*.trigger" | while read TRIGGER_PATH; do
    
    # Check if the file still exists (prevents race conditions)
    if [ ! -f "$TRIGGER_PATH" ]; then
      continue
    fi

    # Extract just the filename for parsing
    TRIGGER_FILE=$(basename "$TRIGGER_PATH")

    echo "---"
    echo "Trigger detected: $TRIGGER_FILE"

    # --- ROUTE 1: Bulk Merge Request ---
    # Filename format: bulk_merge_COMPANY_YYYY-MM-DD.trigger
    # Example: bulk_merge_PPC_2025-10-28.trigger
    if [[ "$TRIGGER_FILE" == bulk_merge_*.trigger ]]; then
      
      # Extract company and date
      TRIGGER_BODY=$(echo "$TRIGGER_FILE" | sed -e 's/bulk_merge_//' -e 's/.trigger//')
      COMPANY=$(echo "$TRIGGER_BODY" | cut -d'_' -f1)
      DATE=$(echo "$TRIGGER_BODY" | cut -d'_' -f2-) # Takes the rest of the string
      
      # --- VALIDATION ---
      # Check if COMPANY or DATE is empty.
      if [ -z "$COMPANY" ] || [ -z "$DATE" ]; then
        echo "Invalid bulk merge format: $TRIGGER_FILE. Must be 'bulk_merge_COMPANY_YYYY-MM-DD.trigger'."
        echo "Aborting."
        rm -f "$TRIGGER_PATH" # Clean up trigger
        continue
      fi
      # --- END VALIDATION ---
      
      echo "Processing BULK merge for Company: $COMPANY on Date: $DATE"
      
      # Define paths based on the company and date
      SOURCE_DIR="/data/$COMPANY/$DATE"
      OUTPUT_DIR="/data/$COMPANY/BulkGenerations"

      mkdir -p "$OUTPUT_DIR"
      
      # 1. Find all PDF files
      files=("$SOURCE_DIR"/*.pdf)
      
      # 2. Check if files were found
      if [ ${#files[@]} -eq 0 ] || [ ! -e "${files[0]}" ]; then
        echo "No PDF files found in $SOURCE_DIR. Aborting."
        rm -f "$TRIGGER_PATH" # Clean up trigger
        continue
      fi
      
      # 3. Build curl arguments
      args=()
      for f in "${files[@]}"; do
        args+=(-F "files=@$f")
      done
      
      # 4. Generate output filename
      OUT_FILE="$OUTPUT_DIR/BULK-$COMPANY-$DATE.pdf"
      
      # 5. Run curl
      echo "Merging ${#files[@]} files to $OUT_FILE..."
      curl --fail -s -X POST "${args[@]}" "http://pdfHandler:3000/forms/pdfengines/merge" -o "$OUT_FILE"
      
      if [ $? -eq 0 ]; then
        echo "Bulk merge successful: $OUT_FILE"
      else
        echo "Bulk merge failed. Check Gotenberg logs."
      fi

    # --- ROUTE 2: Individual Merge Request ---
    # Filename format: individual_merge_COMPANY_ID.trigger
    # Example: individual_merge_PPC_john.doe.trigger
    # Content: This file MUST contain the two full paths to the PDFs to be merged.
    elif [[ "$TRIGGER_FILE" == individual_merge_*.trigger ]]; then
      
      # Extract company and ID
      COMPANY_ID=$(echo "$TRIGGER_FILE" | sed -e 's/individual_merge_//' -e 's/.trigger//')
      COMPANY=$(echo "$COMPANY_ID" | cut -d'_' -f1)
      ID=$(echo "$COMPANY_ID" | cut -d'_' -f2-)
      
      echo "Processing INDIVIDUAL merge for Company: $COMPANY, ID: $ID"
      
      # Define output path
      OUTPUT_DIR="/data/$COMPANY/IndividualGenerations"
      mkdir -p "$OUTPUT_DIR"
      
      # 1. Read the two file paths from *inside* the trigger file
      # We use 'mapfile' (bash 4+) for robustly reading lines into an array
      mapfile -t files_to_merge < "$TRIGGER_PATH"
      
      # 2. Check if we have exactly two files
      if [ "${#files_to_merge[@]}" -ne 2 ]; then
        echo "Error: Trigger file $TRIGGER_FILE did not contain exactly 2 file paths. Aborting."
        rm -f "$TRIGGER_PATH" # Clean up trigger
        continue
      fi

      # 3. Build curl arguments from the two paths
      # We trust the paths are correct as seen by this container (e.g., /data/...)
      args=()
      args+=(-F "files=@${files_to_merge[0]}")
      args+=(-F "files=@${files_to_merge[1]}")
      
      echo "Merging file 1: ${files_to_merge[0]}"
      echo "Merging file 2: ${files_to_merge[1]}"

      # 4. Generate output filename
      OUT_FILE="$OUTPUT_DIR/INDIVIDUAL-$COMPANY_ID.pdf"

      # 5. Run curl
      curl --fail -s -X POST "${args[@]}" "http://pdfHandler:3000/forms/pdfengines/merge" -o "$OUT_FILE"
      
      if [ $? -eq 0 ]; then
        echo "Individual merge successful: $OUT_FILE"
      else
        echo "Individual merge failed. Check Gotenberg logs."
      fi
      
    else
      echo "Unknown trigger format: $TRIGGER_FILE. Ignoring."
    fi

    # --- Cleanup ---
    # Remove the trigger file to reset for the next run
    rm -f "$TRIGGER_PATH"
    echo "Watcher reset."
    echo "---"

  done # End of find loop
  
  # Wait for 5 seconds before checking again
  sleep 5

done # End of main while loop

