#!/bin/bash

# Wrapper script to run debug commands with proper permissions

OPIK_UID=$(id -u opik-user)

echo "=== Frontend service status ==="
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID systemctl --user status opik-frontend.service || true

echo ""
echo "=== Frontend journal logs (last 100 lines) ==="
journalctl --user-unit=opik-frontend.service -n 100 --no-pager 2>/dev/null || \
  sudo journalctl _UID=$OPIK_UID -u opik-frontend.service -n 100 --no-pager 2>/dev/null || \
  echo "Cannot access logs - trying podman logs..."

echo ""
echo "=== Pod status ==="
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID podman pod ps || true

echo ""
echo "=== All opik containers ==="
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID podman ps -a --filter pod=opik || true

echo ""
echo "=== Try to get container logs directly ==="
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID podman logs opik-frontend 2>&1 | tail -50 || echo "No container logs available"

echo ""
echo "=== Test frontend locally ==="
curl -s http://localhost:5173/ 2>&1 | head -30
