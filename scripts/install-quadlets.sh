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

# 1. Set up users
echo "Setting up dedicated users for each service..."

# Create users for each service
# Use fixed, non-overlapping subuid/subgid ranges
declare -A SUBID_RANGES=(
    ["vllm-user"]="200000"
    ["nginx-user"]="265536"
    ["webui-user"]="331072"
    ["dnsmasq-user"]="396608"
    ["opik-user"]="462144"
)

for user_info in "vllm-user:/var/lib/vllm" "nginx-user:/var/lib/nginx-proxy" "webui-user:/var/lib/webui" "dnsmasq-user:/var/lib/dnsmasq-llm" "opik-user:/var/lib/opik"; do
    username="${user_info%:*}"
    homedir="${user_info#*:}"
    subid_start="${SUBID_RANGES[$username]}"

    if ! id -u $username &>/dev/null; then
        sudo useradd -r -s /usr/sbin/nologin -m -d $homedir $username
        echo "✓ Created user: $username"
    else
        echo "✓ User $username already exists"
    fi

    # Add subuid/subgid space for rootless podman (remove duplicates first)
    sudo sed -i "/^$username:/d" /etc/subuid
    sudo sed -i "/^$username:/d" /etc/subgid
    echo "$username:$subid_start:65536" | sudo tee -a /etc/subuid > /dev/null
    echo "$username:$subid_start:65536" | sudo tee -a /etc/subgid > /dev/null
    echo "✓ Configured subuid/subgid for $username: $subid_start:65536"

    # Enable systemd user services
    sudo loginctl enable-linger $username

    # Create and set ownership of podman storage directories for user services
    # (nginx-user and dnsmasq-user use system-level podman, so skip them)
    if [[ "$username" == "vllm-user" || "$username" == "webui-user" || "$username" == "opik-user" ]]; then
        sudo mkdir -p $homedir/.local/share/containers/storage
        sudo mkdir -p $homedir/.cache/containers
        sudo chown -R $username:$username $homedir/.local
        sudo chown -R $username:$username $homedir/.cache
        echo "✓ Initialized podman storage for $username"
    fi
done

echo "✓ All users configured"

echo ""
echo "Creating service directories..."

# Create service-specific directories
sudo mkdir -p /var/lib/nginx-proxy/{conf.d,dist,ssl/dist}
sudo mkdir -p /var/lib/dnsmasq-llm
sudo mkdir -p /var/lib/vllm/.cache/huggingface
sudo mkdir -p /var/lib/webui/data
sudo mkdir -p /var/lib/opik/{mysql,clickhouse/{data,logs,config},zookeeper,minio,config}

# Set ownership for each service's directories
sudo chown -R nginx-user:nginx-user /var/lib/nginx-proxy
sudo chown -R dnsmasq-user:dnsmasq-user /var/lib/dnsmasq-llm
sudo chown -R vllm-user:vllm-user /var/lib/vllm
sudo chown -R webui-user:webui-user /var/lib/webui
sudo chown -R opik-user:opik-user /var/lib/opik

echo ""
echo "Copying configuration files..."

# Copy nginx configs
sudo cp "$REPO_ROOT/config/nginx/nginx.conf" /var/lib/nginx-proxy/
sudo cp "$REPO_ROOT/config/nginx/conf.d"/* /var/lib/nginx-proxy/conf.d/
sudo cp "$SCRIPT_DIR/install-client.sh" /var/lib/nginx-proxy/dist/

# Copy dnsmasq config
sudo cp "$REPO_ROOT/config/dnsmasq/dnsmasq.conf" /var/lib/dnsmasq-llm/

# Copy Opik configs
sudo cp "$REPO_ROOT/config/opik/nginx_default_local.conf" /var/lib/opik/config/
sudo cp "$REPO_ROOT/config/opik/fluent-bit.conf" /var/lib/opik/config/
sudo cp "$REPO_ROOT/config/opik/additional_config.xml" /var/lib/opik/clickhouse/config/

# Set permissions and ownership on config files
sudo find /var/lib/nginx-proxy/conf.d -type f -exec chmod 644 {} \;
sudo chmod 644 /var/lib/nginx-proxy/nginx.conf
sudo chmod 755 /var/lib/nginx-proxy/dist/install-client.sh
sudo chown -R nginx-user:nginx-user /var/lib/nginx-proxy

sudo chmod 644 /var/lib/dnsmasq-llm/dnsmasq.conf
sudo chown -R dnsmasq-user:dnsmasq-user /var/lib/dnsmasq-llm

sudo find /var/lib/opik/config -type f -exec chmod 644 {} \;
sudo find /var/lib/opik/clickhouse/config -type f -exec chmod 644 {} \;
sudo chown -R opik-user:opik-user /var/lib/opik

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
sudo sed -i "s|192.168.0.1|$HOST_IP|g" /var/lib/dnsmasq-llm/dnsmasq.conf

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

# Install user-level quadlets (rootless podman for vllm, webui, and opik)
sudo mkdir -p /var/lib/vllm/.config/containers/systemd
sudo mkdir -p /var/lib/webui/.config/containers/systemd
sudo mkdir -p /var/lib/opik/.config/containers/systemd

sudo cp "$REPO_ROOT/quadlets/vllm-qwen.container" /var/lib/vllm/.config/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/open-webui.container" /var/lib/webui/.config/containers/systemd/

# Copy all Opik quadlets to opik-user's systemd directory
sudo cp "$REPO_ROOT/quadlets/opik.pod" /var/lib/opik/.config/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/opik-mysql.container" /var/lib/opik/.config/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/opik-redis.container" /var/lib/opik/.config/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/opik-zookeeper.container" /var/lib/opik/.config/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/opik-clickhouse.container" /var/lib/opik/.config/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/opik-minio.container" /var/lib/opik/.config/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/opik-minio-init.container" /var/lib/opik/.config/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/opik-backend.container" /var/lib/opik/.config/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/opik-python-backend.container" /var/lib/opik/.config/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/opik-frontend.container" /var/lib/opik/.config/containers/systemd/

# Set ownership of user quadlet files
sudo chown -R vllm-user:vllm-user /var/lib/vllm/.config
sudo chown -R webui-user:webui-user /var/lib/webui/.config
sudo chown -R opik-user:opik-user /var/lib/opik/.config

# Install system-level quadlets (rootful podman for nginx and dnsmasq - need privileged ports)
sudo mkdir -p /etc/containers/systemd
sudo cp "$REPO_ROOT/quadlets/nginx-proxy.container" /etc/containers/systemd/
sudo cp "$REPO_ROOT/quadlets/dnsmasq.container" /etc/containers/systemd/

echo "✓ Installed user quadlets: vllm-qwen, open-webui, opik (pod with 9 containers)"
echo "✓ Installed system quadlets: nginx-proxy, dnsmasq"

echo ""
echo "Generating SSL certificates..."

# Generate SSL certificates before starting nginx
SSL_DIR="/var/lib/nginx-proxy/ssl"
DIST_DIR="/var/lib/nginx-proxy/ssl/dist"

if sudo test -f "$SSL_DIR/liminati.internal.crt" && sudo test -f "$SSL_DIR/liminati.internal.key"; then
    echo "SSL certificates already exist, skipping generation."
    # Ensure cert is copied to dist directories
    sudo cp "$SSL_DIR/liminati.internal.crt" "$DIST_DIR/liminati-ca.crt"
    sudo cp "$SSL_DIR/liminati.internal.crt" /var/lib/nginx-proxy/dist/liminati-ca.crt
    sudo chown nginx-user:nginx-user /var/lib/nginx-proxy/dist/liminati-ca.crt
    sudo chmod 644 /var/lib/nginx-proxy/dist/liminati-ca.crt
else
    CERT_DAYS=3650

    sudo mkdir -p "$SSL_DIR" "$DIST_DIR"

    sudo openssl req -x509 -nodes -days $CERT_DAYS \
        -newkey rsa:4096 \
        -keyout "$SSL_DIR/liminati.internal.key" \
        -out "$SSL_DIR/liminati.internal.crt" \
        -subj "/C=US/ST=State/L=City/O=Liminati/CN=*.liminati.internal" \
        -addext "subjectAltName=DNS:*.liminati.internal,DNS:liminati.internal"

    sudo cp "$SSL_DIR/liminati.internal.crt" "$DIST_DIR/liminati-ca.crt"
    # Also copy to installer dist directory for easy download
    sudo cp "$SSL_DIR/liminati.internal.crt" /var/lib/nginx-proxy/dist/liminati-ca.crt

    sudo chown -R nginx-user:nginx-user "$SSL_DIR"
    sudo chown nginx-user:nginx-user /var/lib/nginx-proxy/dist/liminati-ca.crt
    sudo chmod 640 "$SSL_DIR/liminati.internal.key"
    sudo chmod 644 "$SSL_DIR/liminati.internal.crt"
    sudo chmod 644 "$DIST_DIR/liminati-ca.crt"
    sudo chmod 644 /var/lib/nginx-proxy/dist/liminati-ca.crt

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

# Stop Opik pod containers if running
echo "Stopping Opik pod containers if running..."
OPIK_UID=$(id -u opik-user 2>/dev/null) || OPIK_UID=""
if [ -n "$OPIK_UID" ]; then
    for container in frontend python-backend backend minio-init minio clickhouse zookeeper redis mysql; do
        sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID systemctl --user stop opik-$container.service 2>/dev/null || true
    done
    sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID systemctl --user stop opik-pod.service 2>/dev/null || true
fi

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
# Clean up Opik pod and containers
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$(id -u opik-user) podman pod rm -f opik 2>/dev/null || true

# Kill any orphaned webproc processes from previous dnsmasq runs
echo "Cleaning up orphaned processes..."
sudo pkill -9 webproc 2>/dev/null || true

# Remove corrupted temp directories created by podman rm above
# (podman rm may create temp dirs with wrong ownership when cleaning old containers with mismatched subuid)
echo "Cleaning up corrupted temp directories..."
for user in vllm-user webui-user opik-user; do
    homedir=$(getent passwd $user | cut -d: -f6)
    sudo rm -rf "$homedir/.local/share/containers/storage/overlay/tempdirs" 2>/dev/null || true
done

echo ""
echo "Reloading systemd..."

# Reload systemd for user services
for user in vllm-user webui-user opik-user; do
    VLLM_UID=$(id -u $user)
    echo "Reloading systemd for $user..."
    sudo -u $user XDG_RUNTIME_DIR=/run/user/$VLLM_UID systemctl --user daemon-reload
done

# Reload systemd for system services
echo "Reloading system daemon..."
sudo systemctl daemon-reload

# Fix ownership of podman storage directories AFTER daemon-reload
# (daemon-reload might create files, so fix ownership right before starting services)
echo "Fixing ownership of podman storage..."
for user in vllm-user webui-user opik-user; do
    homedir=$(getent passwd $user | cut -d: -f6)
    if [ -d "$homedir/.local" ]; then
        sudo chown -R $user:$user "$homedir/.local"
    fi
    if [ -d "$homedir/.cache" ]; then
        sudo chown -R $user:$user "$homedir/.cache"
    fi
done

echo ""
echo "Starting services..."

# Start user-level services (rootless podman)
for service_user in "vllm-user:vllm-qwen" "webui-user:open-webui"; do
    user="${service_user%:*}"
    service="${service_user#*:}"
    VLLM_UID=$(id -u $user)
    homedir=$(getent passwd $user | cut -d: -f6)

    # Fix ownership one more time right before starting (in case previous attempts failed)
    sudo chown -R $user:$user "$homedir/.local" 2>/dev/null || true

    if sudo -u $user XDG_RUNTIME_DIR=/run/user/$VLLM_UID systemctl --user is-active --quiet $service.service 2>/dev/null; then
        echo "Restarting $service.service (as $user)..."
        sudo -u $user XDG_RUNTIME_DIR=/run/user/$VLLM_UID systemctl --user restart $service.service
    else
        echo "Starting $service.service (as $user)..."
        sudo -u $user XDG_RUNTIME_DIR=/run/user/$VLLM_UID systemctl --user start $service.service || true
    fi
done

# Start Opik pod (requires starting all container services)
echo "Starting Opik pod containers (as opik-user)..."
OPIK_UID=$(id -u opik-user)
sudo chown -R opik-user:opik-user /var/lib/opik/.local 2>/dev/null || true

# Start pod infrastructure first
sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID systemctl --user start opik-pod.service || true

# Start all Opik containers
for container in mysql redis zookeeper clickhouse minio minio-init backend python-backend frontend; do
    echo "  Starting opik-$container..."
    sudo -u opik-user XDG_RUNTIME_DIR=/run/user/$OPIK_UID systemctl --user start opik-$container.service || true
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
echo "  ✓ vllm, webui & opik run as rootless podman (user services)"
echo "  ✓ nginx & dnsmasq run as rootful podman (system services - need privileged ports)"
echo "  ✓ Each service has its own isolated directory"
echo "  ✓ SSL keys only readable by nginx-user"
echo ""
echo "Services:"
echo "  • vllm-qwen (user service - rootless)"
echo "  • open-webui (user service - rootless)"
echo "  • opik (user service - rootless pod with 9 containers, port 5173)"
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
echo "  Opik:       https://opik.liminati.internal (or http://$HOST_IP:5173)"
echo ""
echo "Check service status:"
echo "  User services (rootless):"
echo "    sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/\$(id -u vllm-user) systemctl --user status vllm-qwen"
echo "    sudo -u webui-user XDG_RUNTIME_DIR=/run/user/\$(id -u webui-user) systemctl --user status open-webui"
echo "    sudo -u opik-user XDG_RUNTIME_DIR=/run/user/\$(id -u opik-user) systemctl --user status opik"
echo ""
echo "  System services (rootful):"
echo "    sudo systemctl status nginx-proxy"
echo "    sudo systemctl status dnsmasq"
echo ""
