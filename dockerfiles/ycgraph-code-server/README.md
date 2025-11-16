# YCGraph Code Server Docker Image

This directory contains the Dockerfile for the YCGraph Dagster code server.

## Purpose

The custom Docker image pre-installs all required dependencies for the ycgraph code location, including:
- Dagster core packages
- Web scraping tools (playwright, beautifulsoup4, lxml)
- Data processing (pandas)
- API clients (openai, requests)
- Data validation (pydantic)

## Building the Image

Use the provided build script:

```bash
cd /home/austin/model-serving/scripts
./build-ycgraph-image.sh
```

Or build manually:

```bash
cd /home/austin/model-serving/dockerfiles/ycgraph-code-server
podman build -t localhost/ycgraph-code-server:latest .
```

## Updating Dependencies

1. Edit the `Dockerfile` to add/remove dependencies
2. Rebuild the image using the build script
3. Restart the container:
   ```bash
   systemctl --user restart ycgraph-code-server.service
   ```

## Container Configuration

The quadlet configuration is located at:
- `/home/austin/model-serving/quadlets/ycgraph-code-server.container`

The container:
- Mounts the ycgraph repository from `/home/austin/ycgraph` (read-only)
- Installs the ycgraph package in editable mode at startup
- Runs the Dagster gRPC server for the code location

## Advantages

- **Faster startup**: Dependencies are pre-installed in the image
- **Reproducibility**: Consistent environment across restarts
- **Version control**: Dockerfile tracks dependency changes
- **Easier updates**: Rebuild image instead of manual pip installs
