#!/bin/bash
set -e

echo "Setting up Grafana + Prometheus monitoring stack..."

# Create necessary directories
mkdir -p ~/model-serving/config/prometheus/data
mkdir -p ~/model-serving/config/grafana/data

# Set proper permissions for data directories
chmod 755 ~/model-serving/config/prometheus/data
chmod 755 ~/model-serving/config/grafana/data

# Pull container images first to avoid timeout issues
echo "Pulling container images..."
podman pull docker.io/prom/prometheus:latest
podman pull docker.io/grafana/grafana:latest
podman pull docker.io/prom/node-exporter:latest

# Copy quadlet files to systemd user directory
mkdir -p ~/.config/containers/systemd
cp ~/model-serving/quadlets/prometheus.container ~/.config/containers/systemd/
cp ~/model-serving/quadlets/grafana.container ~/.config/containers/systemd/
cp ~/model-serving/quadlets/node-exporter.container ~/.config/containers/systemd/

# Reload systemd daemon to pick up new quadlets
systemctl --user daemon-reload

# Start services (quadlets auto-enable via WantedBy in .container files)
echo "Starting monitoring services..."
systemctl --user start prometheus.service
systemctl --user start node-exporter.service
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

# Restart dnsmasq to pick up new DNS record (reload doesn't work for volume-mounted configs)
if sudo systemctl restart dnsmasq.service 2>/dev/null; then
    echo "✓ Dnsmasq restarted successfully (grafana.liminati.internal now resolves)"
else
    echo "⚠ Could not restart dnsmasq (you may need to do this manually)"
    echo "  Run: sudo systemctl restart dnsmasq.service"
fi

# Reload nginx to pick up Grafana configuration
echo ""
echo "Reloading nginx-proxy to enable grafana.liminati.internal..."
if sudo systemctl reload nginx-proxy.service 2>/dev/null; then
    echo "✓ Nginx reloaded successfully"
else
    echo "⚠ Could not reload nginx-proxy (you may need to do this manually)"
    echo "  Run: sudo systemctl reload nginx-proxy.service"
fi

echo ""
echo "Monitoring stack deployed successfully!"
echo ""
echo "Access URLs (via HTTPS/nginx-proxy):"
echo "  Grafana: https://grafana.liminati.internal"
echo ""
echo "Access URLs (direct/localhost):"
echo "  Prometheus: http://localhost:9090"
echo "  Grafana:    http://localhost:3000"
echo "  Node Exporter: http://localhost:9100/metrics"
echo ""
echo "Grafana default credentials:"
echo "  Username: admin"
echo "  Password: admin"
echo ""
echo "Next steps:"
echo "1. Log into Grafana at https://grafana.liminati.internal"
echo "2. Add Prometheus as a data source:"
echo "   - Go to Configuration > Data Sources"
echo "   - Click 'Add data source'"
echo "   - Select 'Prometheus'"
echo "   - Set URL to http://localhost:9090"
echo "   - Click 'Save & Test'"
echo "3. Import vLLM dashboard or create custom dashboards"
echo ""
echo "Note: Make sure grafana.liminati.internal resolves to this server"
echo "      (should work automatically if using the dnsmasq setup)"
echo ""
