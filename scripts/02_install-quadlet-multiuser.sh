#!/bin/bash
set -e

echo "=========================================="
echo "Installing LLM Services with User Isolation"
echo "=========================================="
echo ""

# 1. Run user setup script first
if [ ! -f ./01_setup-users.sh ]; then
    echo "Error: 01_setup-users.sh not found"
    exit 1
fi

chmod +x ./01_setup-users.sh
./01_setup-users.sh

echo ""
echo "Creating shared directory structure..."

# Create shared directory structure
sudo mkdir -p /var/lib/llm-services/{nginx,dnsmasq,ssl}
sudo mkdir -p /var/lib/llm-services/nginx/{conf.d,dist}
sudo mkdir -p /var/lib/llm-services/ssl/dist
sudo mkdir -p /var/lib/vllm/.cache/huggingface
sudo mkdir -p /var/lib/webui/data

# Set group ownership for shared directories
sudo chown -R :llm-services /var/lib/llm-services
sudo chmod -R 2775 /var/lib/llm-services  # setgid bit ensures new files inherit group

# Set specific ownership for each service's private data
sudo chown -R vllm-user:llm-services /var/lib/vllm
sudo chown -R webui-user:llm-services /var/lib/webui

# Make shared configs readable by group
sudo chmod 755 /var/lib/llm-services/nginx
sudo chmod 755 /var/lib/llm-services/nginx/conf.d
sudo chmod 755 /var/lib/llm-services/nginx/dist
sudo chmod 755 /var/lib/llm-services/ssl
sudo chmod 755 /var/lib/llm-services/ssl/dist
sudo chmod 755 /var/lib/llm-services/dnsmasq

echo ""
echo "Copying configuration files..."

# Copy nginx configs
sudo cp ../config/nginx/nginx.conf /var/lib/llm-services/nginx/
sudo cp ../config/nginx/conf.d/* /var/lib/llm-services/nginx/conf.d/
sudo cp install-client.sh /var/lib/llm-services/nginx/dist/

# Copy dnsmasq config
sudo cp ../config/dnsmasq/dnsmasq.conf /var/lib/llm-services/dnsmasq/

# Set permissions on config files
sudo find /var/lib/llm-services/nginx/conf.d -type f -exec chmod 644 {} \;
sudo chmod 644 /var/lib/llm-services/nginx/nginx.conf
sudo chmod 755 /var/lib/llm-services/nginx/dist/install-client.sh
sudo chmod 644 /var/lib/llm-services/dnsmasq/dnsmasq.conf

# Set ownership
sudo chown -R nginx-user:llm-services /var/lib/llm-services/nginx
sudo chown -R dnsmasq-user:llm-services /var/lib/llm-services/dnsmasq
sudo chown -R nginx-user:llm-services /var/lib/llm-services/ssl

echo ""
echo "Detecting Tailscale IP..."

# Detect Tailscale IP
if command -v tailscale &> /dev/null; then
    HOST_IP=$(tailscale ip -4 2>/dev/null || hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
else
    HOST_IP=$(hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
fi

if [ -z "$HOST_IP" ]; then
    HOST_IP=$(hostname -I | awk '{print $1}')
    echo "Warning: Tailscale IP not found, using $HOST_IP"
fi

echo "Host IP: $HOST_IP"

# Update dnsmasq config with actual IP
sudo sed -i "s|192.168.0.1|$HOST_IP|g" /var/lib/llm-services/dnsmasq/dnsmasq.conf

echo ""
echo "Configuring system for DNS on port 53..."

# Disable systemd-resolved DNS stub listener
if systemctl is-active --quiet systemd-resolved; then
    sudo mkdir -p /etc/systemd/resolved.conf.d
    cat <<EOF | sudo tee /etc/systemd/resolved.conf.d/disable-stub.conf
[Resolve]
DNSStubListener=no
EOF
    sudo systemctl restart systemd-resolved
    sudo rm -f /etc/resolv.conf
    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi

echo ""
echo "Installing quadlet files for each service..."

# Install quadlets for each user
sudo mkdir -p /var/lib/vllm/.config/containers/systemd
sudo mkdir -p /var/lib/nginx-proxy/.config/containers/systemd
sudo mkdir -p /var/lib/webui/.config/containers/systemd
sudo mkdir -p /var/lib/dnsmasq-llm/.config/containers/systemd

sudo cp ../quadlets/vllm-qwen.container /var/lib/vllm/.config/containers/systemd/
sudo cp ../quadlets/nginx-proxy.container /var/lib/nginx-proxy/.config/containers/systemd/
sudo cp ../quadlets/open-webui.container /var/lib/webui/.config/containers/systemd/
sudo cp ../quadlets/dnsmasq.container /var/lib/dnsmasq-llm/.config/containers/systemd/

# Set ownership of quadlet files
sudo chown -R vllm-user:vllm-user /var/lib/vllm/.config
sudo chown -R nginx-user:nginx-user /var/lib/nginx-proxy/.config
sudo chown -R webui-user:webui-user /var/lib/webui/.config
sudo chown -R dnsmasq-user:dnsmasq-user /var/lib/dnsmasq-llm/.config

echo ""
echo "Generating SSL certificates..."

# Generate SSL certificates before starting nginx
if sudo test -f /var/lib/llm-services/ssl/liminati.internal.crt && sudo test -f /var/lib/llm-services/ssl/liminati.internal.key; then
    echo "SSL certificates already exist, skipping generation."
else
    # Update SSL generation script to use new path
    SSL_DIR="/var/lib/llm-services/ssl"
    DIST_DIR="/var/lib/llm-services/ssl/dist"
    CERT_DAYS=3650

    sudo mkdir -p "$SSL_DIR" "$DIST_DIR"

    sudo openssl req -x509 -nodes -days $CERT_DAYS \
        -newkey rsa:4096 \
        -keyout "$SSL_DIR/liminati.internal.key" \
        -out "$SSL_DIR/liminati.internal.crt" \
        -subj "/C=US/ST=State/L=City/O=Liminati/CN=*.liminati.internal" \
        -addext "subjectAltName=DNS:*.liminati.internal,DNS:liminati.internal"

    sudo cp "$SSL_DIR/liminati.internal.crt" "$DIST_DIR/liminati-ca.crt"

    sudo chown -R nginx-user:llm-services "$SSL_DIR"
    sudo chmod 640 "$SSL_DIR/liminati.internal.key"
    sudo chmod 644 "$SSL_DIR/liminati.internal.crt"
    sudo chmod 644 "$DIST_DIR/liminati-ca.crt"

    echo "✓ SSL certificates generated"
fi

echo ""
echo "Starting services..."

# Start services for each user
for user in vllm-user webui-user dnsmasq-user nginx-user; do
    VLLM_UID=$(id -u $user)
    echo "Reloading systemd for $user..."
    sudo -u $user XDG_RUNTIME_DIR=/run/user/$VLLM_UID systemctl --user daemon-reload
done

# Start each service
for service_user in "vllm-user:vllm-qwen" "webui-user:open-webui" "dnsmasq-user:dnsmasq" "nginx-user:nginx-proxy"; do
    user="${service_user%:*}"
    service="${service_user#*:}"
    VLLM_UID=$(id -u $user)

    if sudo -u $user XDG_RUNTIME_DIR=/run/user/$VLLM_UID systemctl --user is-active --quiet $service.service 2>/dev/null; then
        echo "Restarting $service.service (as $user)..."
        sudo -u $user XDG_RUNTIME_DIR=/run/user/$VLLM_UID systemctl --user restart $service.service
    else
        echo "Starting $service.service (as $user)..."
        sudo -u $user XDG_RUNTIME_DIR=/run/user/$VLLM_UID systemctl --user start $service.service || true
    fi
done

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Host Tailscale IP: $HOST_IP"
echo ""
echo "Security Model:"
echo "  ✓ Each service runs as its own user"
echo "  ✓ Shared files use group permissions (llm-services)"
echo "  ✓ SSL keys only readable by nginx-user"
echo ""
echo "Users:"
echo "  • vllm-user - runs vLLM service"
echo "  • nginx-user - runs nginx reverse proxy"
echo "  • webui-user - runs Open WebUI"
echo "  • dnsmasq-user - runs DNS server"
echo ""
echo "Next steps:"
echo "1. Configure Tailscale DNS:"
echo "   - Nameservers: $HOST_IP"
echo "   - Search domains: liminati.internal"
echo ""
echo "2. Clients can auto-configure with:"
echo "   curl http://$HOST_IP:8081/install-client.sh | bash -s $HOST_IP"
echo ""
echo "Services:"
echo "  DNS Server: $HOST_IP:53 (UDP/TCP)"
echo "  DNS WebUI:  http://$HOST_IP:5380"
echo "  Installer:  http://$HOST_IP:8081"
echo "  Web UI:     https://webui.liminati.internal"
echo "  vLLM API:   https://vllm.liminati.internal"
echo ""
echo "Check service status:"
echo "  sudo -u nginx-user systemctl --user status nginx-proxy"
echo "  sudo -u vllm-user systemctl --user status vllm-qwen"
echo "  sudo -u webui-user systemctl --user status open-webui"
echo "  sudo -u dnsmasq-user systemctl --user status dnsmasq"
echo ""
