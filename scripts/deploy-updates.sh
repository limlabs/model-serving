#!/bin/bash
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$REPO_ROOT"

echo "=========================================="
echo "Deploying Updates"
echo "=========================================="
echo ""

echo "=== Pulling latest code ==="
git pull

echo ""
echo "=== Copying updated configuration files ==="
sudo cp "$REPO_ROOT/config/opik/nginx_default_local.conf" /var/lib/opik/config/
sudo chown opik-user:opik-user /var/lib/opik/config/nginx_default_local.conf

echo ""
echo "=== Copying updated quadlet files ==="
sudo cp "$REPO_ROOT/quadlets/opik-frontend.container" /var/lib/opik/.config/containers/systemd/
sudo chown opik-user:opik-user /var/lib/opik/.config/containers/systemd/opik-frontend.container

echo ""
echo "=== Reloading systemd ==="
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$(id -u opik-user) systemctl --user daemon-reload

echo ""
echo "=== Restarting opik-frontend ==="
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$(id -u opik-user) systemctl --user restart opik-frontend.service

echo ""
echo "=== Waiting for service to start ==="
sleep 5

echo ""
echo "=== Checking frontend status ==="
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$(id -u opik-user) systemctl --user status opik-frontend.service --no-pager | head -20

echo ""
echo "=== Checking frontend logs ==="
cd /tmp
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$(id -u opik-user) podman logs --tail 20 opik-frontend 2>&1

echo ""
echo "=== Testing localhost:5173 ==="
curl -s -I http://localhost:5173/ | head -10

echo ""
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
