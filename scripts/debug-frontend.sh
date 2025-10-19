#!/bin/bash

# Debug script for opik-frontend issues
# Runs all diagnostic commands needed to troubleshoot the frontend

OPIK_UID=$(id -u opik-user)

echo "=== Frontend service status ==="
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID systemctl --user status opik-frontend.service

echo ""
echo "=== Frontend journal logs (last 100 lines) ==="
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID journalctl --user -u opik-frontend.service -n 100 --no-pager

echo ""
echo "=== Pod status ==="
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID podman pod ps

echo ""
echo "=== All opik containers ==="
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID podman ps -a --filter pod=opik

echo ""
echo "=== Test frontend locally ==="
curl -s http://localhost:5173/ | head -30
