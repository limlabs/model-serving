#!/bin/bash
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "Installing LLM Services with User Isolation"
echo "=========================================="
echo ""
echo "Repository root: $REPO_ROOT"
echo ""

# 1. Set up users and groups
echo "Setting up dedicated users for each service..."

# Create a shared group for services that need to share files
if ! getent group llm-services &>/dev/null; then
    sudo groupadd llm-services
    echo "✓ Created group: llm-services"
fi

# Create users for each service
for user_info in "vllm-user:/var/lib/vllm" "nginx-user:/var/lib/nginx-proxy" "webui-user:/var/lib/webui" "dnsmasq-user:/var/lib/dnsmasq-llm"; do
    username="${user_info%:*}"
    homedir="${user_info#*:}"

    if ! id -u $username &>/dev/null; then
        sudo useradd -r -s /usr/sbin/nologin -m -d $homedir -G llm-services $username
        echo "✓ Created user: $username"
    else
        sudo usermod -aG llm-services $username
        echo "✓ User $username already exists, added to llm-services group"
    fi

    # Add subuid/subgid space for rootless podman
    if ! grep -q "^$username:" /etc/subuid; then
        echo "$username:$(( 100000 + $(id -u $username) * 65536 )):65536" | sudo tee -a /etc/subuid > /dev/null
    fi
    if ! grep -q "^$username:" /etc/subgid; then
        echo "$username:$(( 100000 + $(id -u $username) * 65536 )):65536" | sudo tee -a /etc/subgid > /dev/null
    fi

    # Enable systemd user services
    sudo loginctl enable-linger $username
done

echo "✓ All users configured"

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
sudo cp "$REPO_ROOT/config/nginx/nginx.conf" /var/lib/llm-services/nginx/
sudo cp "$REPO_ROOT/config/nginx/conf.d"/* /var/lib/llm-services/nginx/conf.d/
sudo cp "$SCRIPT_DIR/install-client.sh" /var/lib/llm-services/nginx/dist/

# Copy dnsmasq config
sudo cp "$REPO_ROOT/config/dnsmasq/dnsmasq.conf" /var/lib/llm-services/dnsmasq/

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

# Install user-level quadlets (rootless podman for vllm and webui)
sudo mkdir -p /var/lib/vllm/.config/containers/systemd
sudo mkdir -p /var/lib/webui/.config/containers/systemd

sudo cp "$REPO_ROOT/quadlets/vllm-qwen.container" /var/lib/vllm/.config/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/open-webui.container" /var/lib/webui/.config/containers/systemd/

# Set ownership of user quadlet files
sudo chown -R vllm-user:vllm-user /var/lib/vllm/.config
sudo chown -R webui-user:webui-user /var/lib/webui/.config

# Install system-level quadlets (rootful podman for nginx and dnsmasq - need privileged ports)
sudo mkdir -p /etc/containers/systemd
sudo cp "$REPO_ROOT/quadlets/nginx-proxy.container" /etc/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/dnsmasq.container" /etc/containers/systemd/

echo "✓ Installed user quadlets: vllm-qwen, open-webui"
echo "✓ Installed system quadlets: nginx-proxy, dnsmasq"

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
echo "Stopping existing services..."

# Stop user services if running
for service_user in "vllm-user:vllm-qwen" "webui-user:open-webui"; do
    user="${service_user%:*}"
    service="${service_user#*:}"
    VLLM_UID=$(id -u $user)

    if sudo -u $user XDG_RUNTIME_DIR=/run/user/$VLLM_UID systemctl --user is-active --quiet $service.service 2>/dev/null; then
        echo "Stopping $service.service (user)..."
        sudo -u $user XDG_RUNTIME_DIR=/run/user/$VLLM_UID systemctl --user stop $service.service || true
    fi
done

# Stop system services if running
for service in nginx-proxy dnsmasq; do
    if sudo systemctl is-active --quiet $service.service 2>/dev/null; then
        echo "Stopping $service.service (system)..."
        sudo systemctl stop $service.service || true
    fi
done

# Clean up any orphaned containers and processes
echo "Cleaning up orphaned containers..."
sudo podman rm -f nginx-proxy dnsmasq 2>/dev/null || true
for user in vllm-user webui-user; do
    sudo -u $user XDG_RUNTIME_DIR=/run/user/$(id -u $user) podman rm -f vllm-qwen open-webui 2>/dev/null || true
done

# Kill any orphaned webproc processes from previous dnsmasq runs
echo "Cleaning up orphaned processes..."
sudo pkill -9 webproc 2>/dev/null || true

echo ""
echo "Reloading systemd..."

# Reload systemd for user services
for user in vllm-user webui-user; do
    VLLM_UID=$(id -u $user)
    echo "Reloading systemd for $user..."
    sudo -u $user XDG_RUNTIME_DIR=/run/user/$VLLM_UID systemctl --user daemon-reload
done

# Reload systemd for system services
echo "Reloading system daemon..."
sudo systemctl daemon-reload

# Start user-level services (rootless podman)
for service_user in "vllm-user:vllm-qwen" "webui-user:open-webui"; do
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

# Start system-level services (rootful podman)
for service in nginx-proxy dnsmasq; do
    if sudo systemctl is-active --quiet $service.service 2>/dev/null; then
        echo "Restarting $service.service (system)..."
        sudo systemctl restart $service.service
    else
        echo "Starting $service.service (system)..."
        sudo systemctl start $service.service || true
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
echo "  ✓ vllm & webui run as rootless podman (user services)"
echo "  ✓ nginx & dnsmasq run as rootful podman (system services - need privileged ports)"
echo "  ✓ Shared files use group permissions (llm-services)"
echo "  ✓ SSL keys only readable by nginx container"
echo ""
echo "Services:"
echo "  • vllm-qwen (user service - rootless)"
echo "  • open-webui (user service - rootless)"
echo "  • nginx-proxy (system service - rootful, ports 80/443/8081)"
echo "  • dnsmasq (system service - rootful, port 53)"
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
echo "  User services (rootless):"
echo "    sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/\$(id -u vllm-user) systemctl --user status vllm-qwen"
echo "    sudo -u webui-user XDG_RUNTIME_DIR=/run/user/\$(id -u webui-user) systemctl --user status open-webui"
echo ""
echo "  System services (rootful):"
echo "    sudo systemctl status nginx-proxy"
echo "    sudo systemctl status dnsmasq"
echo ""
