#!/bin/bash
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "Setting up Dagster with Podman Quadlets"
echo "=========================================="
echo ""
echo "Repository root: $REPO_ROOT"
echo ""

# 1. Set up dagster user
echo "Setting up dagster-user..."

DAGSTER_USER="dagster-user"
DAGSTER_HOME="/var/lib/dagster"
SUBID_START="527680"

if ! id -u $DAGSTER_USER &>/dev/null; then
    sudo useradd -r -s /usr/sbin/nologin -m -d $DAGSTER_HOME $DAGSTER_USER
    echo "✓ Created user: $DAGSTER_USER"
else
    echo "✓ User $DAGSTER_USER already exists"
fi

# Add subuid/subgid space for rootless podman (remove duplicates first)
sudo sed -i "/^$DAGSTER_USER:/d" /etc/subuid
sudo sed -i "/^$DAGSTER_USER:/d" /etc/subgid
echo "$DAGSTER_USER:$SUBID_START:65536" | sudo tee -a /etc/subuid > /dev/null
echo "$DAGSTER_USER:$SUBID_START:65536" | sudo tee -a /etc/subgid > /dev/null
echo "✓ Configured subuid/subgid for $DAGSTER_USER: $SUBID_START:65536"

# Enable systemd user services
sudo loginctl enable-linger $DAGSTER_USER

# Create and set ownership of podman storage directories
sudo mkdir -p $DAGSTER_HOME/.local/share/containers/storage
sudo mkdir -p $DAGSTER_HOME/.cache/containers
sudo chown -R $DAGSTER_USER:$DAGSTER_USER $DAGSTER_HOME/.local
sudo chown -R $DAGSTER_USER:$DAGSTER_USER $DAGSTER_HOME/.cache
echo "✓ Initialized podman storage for $DAGSTER_USER"

echo ""
echo "Creating Dagster directories..."

# Create service-specific directories
sudo mkdir -p $DAGSTER_HOME/postgres
sudo mkdir -p $DAGSTER_HOME/dagster_home/{storage,logs,history}
sudo mkdir -p $DAGSTER_HOME/code

# Set ownership
sudo chown -R $DAGSTER_USER:$DAGSTER_USER $DAGSTER_HOME

echo "✓ Directories created"

echo ""
echo "Copying configuration files..."

# Copy Dagster configs
sudo cp "$REPO_ROOT/config/dagster/dagster.yaml" $DAGSTER_HOME/dagster_home/
sudo cp "$REPO_ROOT/config/dagster/workspace.yaml" $DAGSTER_HOME/dagster_home/
sudo cp "$REPO_ROOT/config/dagster/example_pipeline.py" $DAGSTER_HOME/code/

# Set ownership
sudo chown -R $DAGSTER_USER:$DAGSTER_USER $DAGSTER_HOME/dagster_home
sudo chown -R $DAGSTER_USER:$DAGSTER_USER $DAGSTER_HOME/code

echo "✓ Configuration files copied"

echo ""
echo "Configuring nginx and dnsmasq..."

# Copy nginx config for Dagster
if [ -d "/var/lib/nginx-proxy/conf.d" ]; then
    sudo cp "$REPO_ROOT/config/nginx/conf.d/dagster.conf" /var/lib/nginx-proxy/conf.d/
    sudo chown nginx-user:nginx-user /var/lib/nginx-proxy/conf.d/dagster.conf
    sudo chmod 644 /var/lib/nginx-proxy/conf.d/dagster.conf
    echo "✓ Nginx configuration copied"
else
    echo "⚠ Nginx directory not found, skipping nginx config"
fi

# Copy dnsmasq config and update with actual Tailscale IP
if [ -d "/var/lib/dnsmasq-llm" ]; then
    # Detect Tailscale IP
    if command -v tailscale &> /dev/null; then
        HOST_IP=$(tailscale ip -4 2>/dev/null || hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    else
        HOST_IP=$(hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    fi
    
    if [ -z "$HOST_IP" ]; then
        echo "⚠ Could not detect Tailscale IP, using placeholder"
        HOST_IP="192.168.0.1"
    else
        echo "Detected Tailscale IP: $HOST_IP"
    fi
    
    sudo cp "$REPO_ROOT/config/dnsmasq/dnsmasq.conf" /var/lib/dnsmasq-llm/
    sudo sed -i "s|192.168.0.1|$HOST_IP|g" /var/lib/dnsmasq-llm/dnsmasq.conf
    sudo chown dnsmasq-user:dnsmasq-user /var/lib/dnsmasq-llm/dnsmasq.conf
    sudo chmod 644 /var/lib/dnsmasq-llm/dnsmasq.conf
    echo "✓ DNSmasq configuration copied and updated"
else
    echo "⚠ DNSmasq directory not found, skipping dnsmasq config"
fi

echo ""
echo "Installing quadlet files..."

# Create systemd directory for user
SYSTEMD_DIR="$DAGSTER_HOME/.config/containers/systemd"
sudo mkdir -p "$SYSTEMD_DIR"

# Copy quadlet files
sudo cp "$REPO_ROOT/quadlets/dagster-network.network" "$SYSTEMD_DIR/"
sudo cp "$REPO_ROOT/quadlets/dagster-postgres.container" "$SYSTEMD_DIR/"
sudo cp "$REPO_ROOT/quadlets/dagster-daemon.container" "$SYSTEMD_DIR/"
sudo cp "$REPO_ROOT/quadlets/dagster-webserver.container" "$SYSTEMD_DIR/"

# Set ownership
sudo chown -R $DAGSTER_USER:$DAGSTER_USER "$SYSTEMD_DIR"

echo "✓ Quadlet files installed"

echo ""
echo "Reloading systemd and starting services..."

# Ensure XDG_RUNTIME_DIR exists
DAGSTER_UID=$(id -u $DAGSTER_USER)
DAGSTER_RUNTIME_DIR="/run/user/$DAGSTER_UID"

if [ ! -d "$DAGSTER_RUNTIME_DIR" ]; then
    echo "Creating runtime directory for $DAGSTER_USER..."
    sudo mkdir -p "$DAGSTER_RUNTIME_DIR"
    sudo chown $DAGSTER_USER:$DAGSTER_USER "$DAGSTER_RUNTIME_DIR"
    sudo chmod 700 "$DAGSTER_RUNTIME_DIR"
fi

# Reload systemd for the user
sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user daemon-reload

# Start services in order
echo "Starting dagster-network..."
sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user start dagster-network-network.service

echo "Starting dagster-postgres..."
sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user start dagster-postgres.service

# Wait for postgres to be ready
echo "Waiting for PostgreSQL to be ready..."
sleep 10

echo "Starting dagster-daemon..."
sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user start dagster-daemon.service

echo "Starting dagster-webserver..."
sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user start dagster-webserver.service

echo ""
echo "✓ All services started"

# Reload nginx and dnsmasq if they exist
"$SCRIPT_DIR/reload-nginx-dnsmasq.sh"

echo ""
echo "=========================================="
echo "Dagster Setup Complete!"
echo "=========================================="
echo ""
echo "Access Dagster UI at:"
echo "  - Local: http://localhost:3002"
echo "  - HTTPS: https://dagster.liminati.internal (via nginx)"
echo ""
echo "Useful commands:"
echo ""
echo "Check service status:"
echo "  sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=/run/user/\$(id -u $DAGSTER_USER) systemctl --user status dagster-webserver"
echo ""
echo "View logs:"
echo "  sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=/run/user/\$(id -u $DAGSTER_USER) journalctl --user -u dagster-webserver -f"
echo ""
echo "Restart services:"
echo "  sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=/run/user/\$(id -u $DAGSTER_USER) systemctl --user restart dagster-webserver"
echo ""
echo "Stop all services:"
echo "  sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=/run/user/\$(id -u $DAGSTER_USER) systemctl --user stop dagster-webserver dagster-daemon dagster-postgres dagster-network"
echo ""
echo "Add your Dagster code to: $DAGSTER_HOME/code/"
echo "Update workspace.yaml to reference your code locations"
echo ""
