#!/bin/bash
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

DAGSTER_USER="dagster-user"
DAGSTER_HOME="/var/lib/dagster"
DAGSTER_UID=$(id -u $DAGSTER_USER 2>/dev/null || echo "")
DAGSTER_RUNTIME_DIR="/run/user/$DAGSTER_UID"
WORKSPACE_YAML="$DAGSTER_HOME/dagster_home/workspace.yaml"

# Check if dagster-user exists
if [ -z "$DAGSTER_UID" ]; then
    echo "ERROR: dagster-user does not exist. Please run setup-dagster.sh first."
    exit 1
fi

echo "=========================================="
echo "Managing Dagster Code Locations"
echo "=========================================="
echo ""

# Function to add code location to workspace.yaml
add_to_workspace() {
    local location_type=$1
    local location_config=$2
    local location_name=$3
    
    if sudo test -f "$WORKSPACE_YAML"; then
        if ! sudo grep -q "$location_name" "$WORKSPACE_YAML"; then
            echo "Adding $location_name to workspace..."
            echo "$location_config" | sudo tee -a "$WORKSPACE_YAML" > /dev/null
            echo "✓ $location_name added to workspace"
            return 0
        else
            echo "✓ $location_name already in workspace"
            return 1
        fi
    else
        echo "ERROR: workspace.yaml not found at $WORKSPACE_YAML"
        exit 1
    fi
}

# Function to restart dagster services
restart_services() {
    echo ""
    echo "Restarting Dagster services..."
    sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user restart dagster-webserver
    sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user restart dagster-daemon
    echo "✓ Services restarted"
}

# Setup ycgraph code location
setup_ycgraph() {
    echo ""
    echo "=========================================="
    echo "Setting up ycgraph code location"
    echo "=========================================="
    echo ""
    
    YCGRAPH_DIR="$DAGSTER_HOME/code/ycgraph"
    
    # Determine the actual user running this script (not root)
    if [ -n "$SUDO_USER" ]; then
        ACTUAL_USER="$SUDO_USER"
        ACTUAL_HOME=$(eval echo ~$SUDO_USER)
    else
        ACTUAL_USER=$(whoami)
        ACTUAL_HOME="$HOME"
    fi
    
    # Check if user has ycgraph in their home directory
    USER_YCGRAPH=""
    
    # First check the actual user's home directory
    if [ -d "$ACTUAL_HOME/ycgraph/.git" ]; then
        USER_YCGRAPH="$ACTUAL_HOME/ycgraph"
        echo "Found ycgraph repository at: $USER_YCGRAPH"
    else
        # Check other users' home directories
        for user_home in /home/*; do
            if [ -d "$user_home/ycgraph/.git" ]; then
                USER_YCGRAPH="$user_home/ycgraph"
                echo "Found ycgraph repository at: $USER_YCGRAPH"
                break
            fi
        done
    fi
    
    # If no user repo found, clone it to the actual user's home directory
    if [ -z "$USER_YCGRAPH" ]; then
        USER_YCGRAPH="$ACTUAL_HOME/ycgraph"
        
        # Check if directory exists but isn't a git repo
        if [ -d "$USER_YCGRAPH" ] && [ ! -d "$USER_YCGRAPH/.git" ]; then
            echo "Removing non-git directory at: $USER_YCGRAPH"
            rm -rf "$USER_YCGRAPH"
        fi
        
        if [ ! -d "$USER_YCGRAPH" ]; then
            echo "Cloning ycgraph to: $USER_YCGRAPH"
            # Clone as the actual user (not with sudo) so it uses their git credentials
            if [ "$ACTUAL_USER" = "$(whoami)" ]; then
                git clone https://github.com/limlabs/ycgraph.git "$USER_YCGRAPH"
            else
                sudo -u "$ACTUAL_USER" git clone https://github.com/limlabs/ycgraph.git "$USER_YCGRAPH"
            fi
            echo "✓ Repository cloned"
        else
            echo "✓ Repository already exists at: $USER_YCGRAPH"
        fi
    fi
    
    # Remove symlink if it exists (we're using volume mounts now)
    if sudo test -L "$YCGRAPH_DIR"; then
        echo "Removing old symlink..."
        sudo rm -f "$YCGRAPH_DIR"
    fi
    
    # Build the ycgraph code server Docker image
    echo ""
    echo "Building ycgraph code server Docker image..."
    if [ -f "$SCRIPT_DIR/build-ycgraph-image.sh" ]; then
        "$SCRIPT_DIR/build-ycgraph-image.sh"
    else
        echo "⚠ Build script not found, attempting manual build..."
        DOCKERFILE_DIR="$REPO_ROOT/dockerfiles/ycgraph-code-server"
        if [ -d "$DOCKERFILE_DIR" ]; then
            echo "Building as dagster-user..."
            sudo -u $DAGSTER_USER bash -c "cd /tmp && XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR podman build -t localhost/ycgraph-code-server:latest $DOCKERFILE_DIR"
            
            # Clean up any duplicate images in other user registries
            if podman images 2>/dev/null | grep -q "localhost/ycgraph-code-server"; then
                echo "Cleaning up duplicate image in current user's registry..."
                podman rmi localhost/ycgraph-code-server:latest 2>/dev/null || true
            fi
            
            echo "✓ Image built successfully"
        else
            echo "ERROR: Dockerfile not found at $DOCKERFILE_DIR"
            echo "Please ensure the Dockerfile exists before running this script."
            exit 1
        fi
    fi
    
    # Ensure dagster-user can access the ycgraph directory
    echo ""
    echo "Setting permissions for ycgraph directory..."
    chmod +rx "$ACTUAL_HOME" 2>/dev/null || true
    chmod -R o+rX "$USER_YCGRAPH" 2>/dev/null || true
    echo "✓ Permissions set"
    
    # Setup ycgraph code server container
    echo ""
    echo "Setting up ycgraph code server container..."
    SYSTEMD_DIR="$DAGSTER_HOME/.config/containers/systemd"
    
    # Copy ycgraph code server quadlet (always update to ensure latest version)
    sudo cp "$REPO_ROOT/quadlets/ycgraph-code-server.container" "$SYSTEMD_DIR/"
    # Replace /home/austin with actual user home if different
    if [ "$ACTUAL_HOME" != "/home/austin" ]; then
        sudo sed -i "s|/home/austin/ycgraph|$ACTUAL_HOME/ycgraph|g" "$SYSTEMD_DIR/ycgraph-code-server.container"
    fi
    sudo chown $DAGSTER_USER:$DAGSTER_USER "$SYSTEMD_DIR/ycgraph-code-server.container"
    
    # Check if quadlet changed
    if ! sudo test -f "$SYSTEMD_DIR/ycgraph-code-server.container.bak" || ! sudo diff -q "$SYSTEMD_DIR/ycgraph-code-server.container" "$SYSTEMD_DIR/ycgraph-code-server.container.bak" > /dev/null 2>&1; then
        echo "✓ Updated ycgraph-code-server.container"
        sudo cp "$SYSTEMD_DIR/ycgraph-code-server.container" "$SYSTEMD_DIR/ycgraph-code-server.container.bak"
        NEEDS_RESTART=true
    else
        echo "✓ ycgraph-code-server.container unchanged"
    fi
    
    echo ""
    echo "✓ ycgraph will be mounted from: $USER_YCGRAPH"
    echo "  Running in separate container with Python 3.12"
    echo "  You can manage the repository from your home directory"
    echo "  Changes will be automatically visible to Dagster"
    
    # Add ycgraph to workspace.yaml as grpc_server
    WORKSPACE_CONFIG='  - grpc_server:
      host: localhost
      port: 4000
      location_name: ycgraph'
    
    # Add to workspace if not already present
    if add_to_workspace "grpc_server" "$WORKSPACE_CONFIG" "ycgraph"; then
        NEEDS_RESTART=true
    fi
    
    # Reload systemd to pick up quadlet changes
    if [ "$NEEDS_RESTART" = true ]; then
        echo ""
        echo "Reloading systemd daemon..."
        sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user daemon-reload
    fi
    
    if [ "$NEEDS_RESTART" = true ]; then
        # Start ycgraph code server
        echo ""
        echo "Starting ycgraph code server..."
        sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user start ycgraph-code-server.service
        
        # Restart main services
        restart_services
        echo "Waiting for containers to be ready..."
        sleep 5
    fi
    
    echo ""
    echo "✓ ycgraph code location setup complete!"
    echo ""
    echo "Check status:"
    echo "  sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=/run/user/\$(id -u $DAGSTER_USER) systemctl --user status ycgraph-code-server"
}

# Setup example S3 assets
setup_example_s3() {
    echo ""
    echo "=========================================="
    echo "Setting up example S3 assets"
    echo "=========================================="
    echo ""
    
    # Copy example assets (only if they don't exist)
    if ! sudo test -f "$DAGSTER_HOME/code/example_s3_assets.py"; then
        echo "Copying example S3 assets template..."
        if [ -f "$REPO_ROOT/config/dagster/example_s3_assets.py" ]; then
            sudo cp "$REPO_ROOT/config/dagster/example_s3_assets.py" $DAGSTER_HOME/code/
            sudo chown $DAGSTER_USER:$DAGSTER_USER $DAGSTER_HOME/code/example_s3_assets.py
            echo "✓ Example template copied"
        else
            echo "⚠ Example template not found at $REPO_ROOT/config/dagster/example_s3_assets.py"
            return 1
        fi
    else
        echo "✓ Example S3 assets already exist"
    fi
    
    # Add to workspace.yaml
    WORKSPACE_CONFIG='  - python_file:
      relative_path: /opt/dagster/code/example_s3_assets.py
      working_directory: /opt/dagster/code'
    
    if add_to_workspace "python_file" "$WORKSPACE_CONFIG" "example_s3_assets.py"; then
        restart_services
    fi
    
    echo ""
    echo "✓ Example S3 assets setup complete!"
}

# List current code locations
list_locations() {
    echo ""
    echo "=========================================="
    echo "Current Code Locations"
    echo "=========================================="
    echo ""
    
    if [ -f "$WORKSPACE_YAML" ]; then
        echo "Workspace configuration:"
        sudo cat "$WORKSPACE_YAML"
    else
        echo "⚠ workspace.yaml not found"
    fi
    
    echo ""
    echo "Code directory contents:"
    sudo ls -lh "$DAGSTER_HOME/code/" 2>/dev/null || echo "⚠ Code directory not found"
}

# Remove a code location
remove_location() {
    local location_name=$1
    
    if [ -z "$location_name" ]; then
        echo "ERROR: Please specify a location name to remove"
        echo "Usage: $0 remove <location_name>"
        exit 1
    fi
    
    echo ""
    echo "=========================================="
    echo "Removing code location: $location_name"
    echo "=========================================="
    echo ""
    
    # Remove from workspace.yaml
    if [ -f "$WORKSPACE_YAML" ]; then
        if sudo grep -q "$location_name" "$WORKSPACE_YAML"; then
            # Create a backup
            sudo cp "$WORKSPACE_YAML" "$WORKSPACE_YAML.backup"
            echo "✓ Created backup: $WORKSPACE_YAML.backup"
            
            # Remove the location (this is a simple approach - may need refinement)
            echo "⚠ Manual removal required. Please edit $WORKSPACE_YAML"
            echo "  and remove the section containing '$location_name'"
        else
            echo "⚠ Location '$location_name' not found in workspace.yaml"
        fi
    fi
}

# Main command dispatcher
case "${1:-}" in
    ycgraph)
        setup_ycgraph
        ;;
    example-s3)
        setup_example_s3
        ;;
    list)
        list_locations
        ;;
    remove)
        remove_location "$2"
        ;;
    all)
        setup_ycgraph
        setup_example_s3
        ;;
    *)
        echo "Usage: $0 {ycgraph|example-s3|all|list|remove <name>}"
        echo ""
        echo "Commands:"
        echo "  ycgraph      - Setup/update ycgraph code location"
        echo "  example-s3   - Setup example S3 assets"
        echo "  all          - Setup all code locations"
        echo "  list         - List current code locations"
        echo "  remove <name> - Remove a code location"
        echo ""
        echo "Examples:"
        echo "  $0 ycgraph          # Setup ycgraph"
        echo "  $0 all              # Setup all locations"
        echo "  $0 list             # Show current locations"
        exit 1
        ;;
esac

echo ""
echo "Done!"
