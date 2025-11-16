#!/bin/bash
set -e

echo "Setting up Grafana + Prometheus monitoring stack..."

# Create necessary directories
mkdir -p ~/model-serving/config/prometheus/data
mkdir -p ~/model-serving/config/grafana/data
mkdir -p ~/model-serving/config/grafana/provisioning/datasources

# Set proper permissions for data directories
chmod 755 ~/model-serving/config/prometheus/data
chmod 755 ~/model-serving/config/grafana/data

# Set ownership for data directories (Prometheus runs as UID 65534, Grafana as UID 472)
echo "Setting data directory ownership..."
podman unshare chown -R 65534:65534 ~/model-serving/config/prometheus/data
podman unshare chown -R 472:472 ~/model-serving/config/grafana/data

# Pull container images first to avoid timeout issues
echo "Pulling container images..."
podman pull docker.io/prom/prometheus:latest
podman pull docker.io/grafana/grafana:latest
podman pull docker.io/prom/node-exporter:latest
podman pull nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04

# Copy quadlet files to systemd user directory
mkdir -p ~/.config/containers/systemd
cp ~/model-serving/quadlets/prometheus.container ~/.config/containers/systemd/
cp ~/model-serving/quadlets/grafana.container ~/.config/containers/systemd/
cp ~/model-serving/quadlets/node-exporter.container ~/.config/containers/systemd/
cp ~/model-serving/quadlets/dcgm-exporter.container ~/.config/containers/systemd/

# Reload systemd daemon to pick up new quadlets
systemctl --user daemon-reload

# Start services (quadlets auto-enable via WantedBy in .container files)
echo "Starting monitoring services..."
systemctl --user start prometheus.service
systemctl --user start node-exporter.service
systemctl --user start dcgm-exporter.service
systemctl --user start grafana.service

# Wait a moment for services to initialize
sleep 2

# Check service status
echo ""
echo "Service status:"
if systemctl --user is-active --quiet prometheus.service; then
    echo "✓ Prometheus is running"
else
    echo "✗ Prometheus failed to start"
    echo "  Logs:"
    journalctl --user -u prometheus.service -n 20 --no-pager | sed 's/^/    /'
fi

if systemctl --user is-active --quiet node-exporter.service; then
    echo "✓ Node Exporter is running"
else
    echo "✗ Node Exporter failed to start"
    echo "  Logs:"
    journalctl --user -u node-exporter.service -n 20 --no-pager | sed 's/^/    /'
fi

if systemctl --user is-active --quiet dcgm-exporter.service; then
    echo "✓ DCGM Exporter is running (GPU metrics)"
else
    echo "✗ DCGM Exporter failed to start"
    echo "  Note: This requires NVIDIA GPU and drivers"
    echo "  Logs:"
    journalctl --user -u dcgm-exporter.service -n 20 --no-pager | sed 's/^/    /'
fi

if systemctl --user is-active --quiet grafana.service; then
    echo "✓ Grafana is running"
else
    echo "✗ Grafana failed to start"
    echo "  Logs:"
    journalctl --user -u grafana.service -n 20 --no-pager | sed 's/^/    /'
    echo ""
    echo "  Checking permissions on data directory..."
    ls -la ~/model-serving/config/grafana/
    echo ""
    echo "  Attempting to fix permissions..."
    chmod -R 755 ~/model-serving/config/grafana/data
    chown -R $(id -u):$(id -g) ~/model-serving/config/grafana/data
    echo "  Restarting Grafana..."
    systemctl --user restart grafana.service
    sleep 2
    if systemctl --user is-active --quiet grafana.service; then
        echo "  ✓ Grafana started successfully after permissions fix"
    else
        echo "  ✗ Grafana still failing. Check logs with: journalctl --user -u grafana.service -f"
    fi
fi

# Update dnsmasq configuration with grafana DNS record
echo ""
echo "Updating dnsmasq configuration..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Copy updated dnsmasq config
sudo cp "$REPO_ROOT/config/dnsmasq/dnsmasq.conf" /var/lib/dnsmasq-llm/

# Detect Tailscale IP and update dnsmasq config
if command -v tailscale &> /dev/null; then
    HOST_IP=$(tailscale ip -4 2>/dev/null || hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
else
    HOST_IP=$(hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
fi

if [ -z "$HOST_IP" ]; then
    HOST_IP=$(hostname -I | awk '{print $1}')
fi

sudo sed -i "s|192.168.0.1|$HOST_IP|g" /var/lib/dnsmasq-llm/dnsmasq.conf

# Copy Grafana nginx config
echo ""
echo "Configuring nginx-proxy for grafana.liminati.internal..."
if sudo cp "$REPO_ROOT/config/nginx/conf.d/grafana.conf" /var/lib/nginx-proxy/conf.d/ 2>/dev/null; then
    echo "✓ Grafana nginx config copied"
else
    echo "⚠ Could not copy nginx config (you may need to do this manually)"
    echo "  Run: sudo cp $REPO_ROOT/config/nginx/conf.d/grafana.conf /var/lib/nginx-proxy/conf.d/"
fi

# Reload nginx and dnsmasq to apply changes
echo ""
"$SCRIPT_DIR/reload-nginx-dnsmasq.sh"

echo ""
echo "Monitoring stack deployed successfully!"
echo ""
echo "Access URLs (via HTTPS/nginx-proxy):"
echo "  Grafana: https://grafana.liminati.internal"
echo ""
echo "Access URLs (direct/localhost):"
echo "  Prometheus: http://localhost:9091"
echo "  Grafana:    http://localhost:3001"
echo "  Node Exporter: http://localhost:9100/metrics"
echo "  DCGM Exporter (GPU): http://localhost:9400/metrics"
echo ""
echo "Grafana default credentials:"
echo "  Username: admin"
echo "  Password: admin"
echo ""
echo "Next steps:"
echo "1. Log into Grafana at https://grafana.liminati.internal"
echo "   - Username: admin"
echo "   - Password: admin (change on first login)"
echo "2. Prometheus data source is already configured automatically!"
echo "3. Import vLLM dashboard or create custom dashboards:"
echo "   - Click '+' > Import"
echo "   - Enter dashboard ID or upload JSON"
echo "   - Select 'Prometheus' as the data source"
echo ""
echo "Note: Make sure grafana.liminati.internal resolves to this server"
echo "      (should work automatically if using the dnsmasq setup)"
echo ""
