#!/bin/bash
set -e

# Build YCGraph Code Server Docker Image
# This script builds the custom Docker image for the ycgraph code server

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKERFILE_DIR="$PROJECT_ROOT/dockerfiles/ycgraph-code-server"
YCGRAPH_DIR="/home/austin/ycgraph"
IMAGE_NAME="localhost/ycgraph-code-server:latest"

echo "Building YCGraph Code Server image..."
echo "Dockerfile location: $DOCKERFILE_DIR"
echo "Image name: $IMAGE_NAME"
echo ""

# Build the image as dagster-user so it's accessible to the service
DAGSTER_USER="dagster-user"
DAGSTER_UID=$(id -u $DAGSTER_USER 2>/dev/null)

if [ -n "$DAGSTER_UID" ]; then
    echo "Building as dagster-user..."
    sudo -u $DAGSTER_USER bash -c "cd /tmp && XDG_RUNTIME_DIR=/run/user/$DAGSTER_UID podman build -t $IMAGE_NAME -f $DOCKERFILE_DIR/Dockerfile $YCGRAPH_DIR"
    
    # Clean up any duplicate images in other user registries
    if podman images | grep -q "localhost/ycgraph-code-server"; then
        echo "Cleaning up duplicate image in current user's registry..."
        podman rmi localhost/ycgraph-code-server:latest 2>/dev/null || true
    fi
else
    echo "Warning: dagster-user not found, building as current user..."
    podman build -t "$IMAGE_NAME" -f "$DOCKERFILE_DIR/Dockerfile" "$YCGRAPH_DIR"
fi

echo ""
echo "✓ Image built successfully: $IMAGE_NAME"
echo ""
echo "To restart the ycgraph code server with the new image:"
echo "  systemctl --user restart ycgraph-code-server.service"
echo ""
echo "To view logs:"
echo "  journalctl --user -u ycgraph-code-server.service -f"
