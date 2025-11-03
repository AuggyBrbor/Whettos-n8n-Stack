# Use a lightweight base image
FROM alpine:latest

# Install necessary tools as root
# We need bash for the script, curl for Gotenberg,
# and inotify-tools for the file watcher
RUN apk add --no-cache bash curl inotify-tools

# --- THIS IS THE KEY CHANGE ---
# Create a 'node' group and 'node' user with the
# same UID (1000) and GID (1000) as the n8n container.
RUN addgroup -g 1000 node && \
    adduser -u 1000 -G node -D -h /home/node node
# --- END CHANGE ---

# Copy the watcher script into the container
COPY watch.sh /watch.sh
RUN chmod +x /watch.sh

# Set the entrypoint for the container
# This will be run as user 1000, defined in docker-compose.yml
ENTRYPOINT ["/watch.sh"]

