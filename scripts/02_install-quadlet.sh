# 1. Create a dedicated user (no login shell, no home directory login)
sudo useradd -r -s /usr/sbin/nologin -m -d /var/lib/vllm vllm-user
sudo usermod -aG systemd-journal vllm-use

# Add subuid/subgid space for vllm-user to pull images
echo "vllm-user:100000:65536" | sudo tee -a /etc/subuid
echo "vllm-user:100000:65536" | sudo tee -a /etc/subgid

# 2. Enable systemd user services for this user
sudo loginctl enable-linger vllm-user

# 3. Set up the quadlet directory
sudo mkdir -p /var/lib/vllm/.config/containers/systemd/user
sudo cp ../quadlets/vllm-qwen.container /var/lib/vllm/.config/containers/systemd/
sudo cp ../quadlets/open-webui.container /var/lib/vllm/.config/containers/systemd/
sudo cp ../quadlets/nginx-proxy.container /var/lib/vllm/.config/containers/systemd/
sudo cp ../quadlets/dnsmasq.container /var/lib/vllm/.config/containers/systemd/

# 4. Create the cache directory
sudo mkdir -p /var/lib/vllm/.cache/huggingface

# 5. Set up nginx configuration directories
sudo mkdir -p /var/lib/vllm/nginx/conf.d
sudo mkdir -p /var/lib/vllm/nginx/ssl
sudo mkdir -p /var/lib/vllm/nginx/dist
sudo cp -r ../config/nginx/nginx.conf /var/lib/vllm/nginx/
sudo cp -r ../config/nginx/conf.d/* /var/lib/vllm/nginx/conf.d/
sudo cp install-client.sh /var/lib/vllm/nginx/dist/
sudo chmod +x /var/lib/vllm/nginx/dist/install-client.sh

# 6. Set up dnsmasq configuration
sudo mkdir -p /var/lib/vllm/dnsmasq
sudo cp ../config/dnsmasq/dnsmasq.conf /var/lib/vllm/dnsmasq/

# Detect Tailscale IP (100.x.x.x range) or fall back to first IP
if command -v tailscale &> /dev/null; then
    HOST_IP=$(tailscale ip -4 2>/dev/null || hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
else
    HOST_IP=$(hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
fi

# Fallback to first IP if no Tailscale IP found
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(hostname -I | awk '{print $1}')
    echo "Warning: Tailscale IP not found, using $HOST_IP"
    echo "Install Tailscale first if you want to use it for DNS"
fi

# Update the IP address in dnsmasq.conf to the actual host IP
sudo sed -i "s|192.168.0.1|$HOST_IP|g" /var/lib/vllm/dnsmasq/dnsmasq.conf

sudo chown -R vllm-user:vllm-user /var/lib/vllm

# Restrict user from su/sudo
echo "vllm-user ALL=(ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers.d/vllm-user
sudo chmod 0440 /etc/sudoers.d/vllm-user

sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/$(id -u vllm-user) systemctl --user daemon-reload
sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/$(id -u vllm-user) systemctl --user start vllm-qwen.service
sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/$(id -u vllm-user) systemctl --user start open-webui.service
sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/$(id -u vllm-user) systemctl --user start dnsmasq.service
sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/$(id -u vllm-user) systemctl --user start nginx-proxy.service

echo ""
echo "=========================================="
echo "Services started successfully!"
echo "=========================================="
echo ""
echo "Host Tailscale IP: $HOST_IP"
echo ""
echo "Next steps:"
echo "1. Run ./03_generate-ssl-cert.sh to create SSL certificates"
echo "2. Restart nginx after cert generation:"
echo "   sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/\$(id -u vllm-user) systemctl --user restart nginx-proxy.service"
echo ""
echo "3. Configure Tailscale DNS settings:"
echo "   - Add nameserver: $HOST_IP"
echo "   - Add search domain: liminati.internal"
echo "   OR use Tailscale admin console to set global nameserver"
echo ""
echo "4. Clients can auto-configure with:"
echo "   curl http://$HOST_IP:8080/install-client.sh | bash -s $HOST_IP"
echo ""
echo "Services accessible at:"
echo "  DNS Server: $HOST_IP:53"
echo "  Web UI:     https://webui.liminati.internal"
echo "  vLLM API:   https://vllm.liminati.internal"
echo ""