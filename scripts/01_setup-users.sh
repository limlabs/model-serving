#!/bin/bash
set -e

echo "Setting up dedicated users for each service..."

# Create a shared group for services that need to share files
if ! getent group llm-services &>/dev/null; then
    sudo groupadd llm-services
    echo "Created group: llm-services"
fi

# 1. Create vllm user
if ! id -u vllm-user &>/dev/null; then
    sudo useradd -r -s /usr/sbin/nologin -m -d /var/lib/vllm -G llm-services vllm-user
    echo "Created user: vllm-user"
else
    sudo usermod -aG llm-services vllm-user
    echo "Added vllm-user to llm-services group"
fi

# 2. Create nginx user
if ! id -u nginx-user &>/dev/null; then
    sudo useradd -r -s /usr/sbin/nologin -m -d /var/lib/nginx-proxy -G llm-services nginx-user
    echo "Created user: nginx-user"
else
    sudo usermod -aG llm-services nginx-user
    echo "Added nginx-user to llm-services group"
fi

# 3. Create webui user
if ! id -u webui-user &>/dev/null; then
    sudo useradd -r -s /usr/sbin/nologin -m -d /var/lib/webui -G llm-services webui-user
    echo "Created user: webui-user"
else
    sudo usermod -aG llm-services webui-user
    echo "Added webui-user to llm-services group"
fi

# 4. Create dnsmasq user
if ! id -u dnsmasq-user &>/dev/null; then
    sudo useradd -r -s /usr/sbin/nologin -m -d /var/lib/dnsmasq-llm -G llm-services dnsmasq-user
    echo "Created user: dnsmasq-user"
else
    sudo usermod -aG llm-services dnsmasq-user
    echo "Added dnsmasq-user to llm-services group"
fi

# Add subuid/subgid space for each user (for rootless podman)
for user in vllm-user nginx-user webui-user dnsmasq-user; do
    if ! grep -q "^$user:" /etc/subuid; then
        echo "$user:$(( 100000 + $(id -u $user) * 65536 )):65536" | sudo tee -a /etc/subuid
    fi
    if ! grep -q "^$user:" /etc/subgid; then
        echo "$user:$(( 100000 + $(id -u $user) * 65536 )):65536" | sudo tee -a /etc/subgid
    fi

    # Enable systemd user services
    sudo loginctl enable-linger $user
done

echo ""
echo "✓ User setup complete!"
echo ""
echo "Users created:"
echo "  - vllm-user (runs vLLM service)"
echo "  - nginx-user (runs nginx reverse proxy)"
echo "  - webui-user (runs Open WebUI)"
echo "  - dnsmasq-user (runs DNS server)"
echo ""
echo "All users are in the 'llm-services' group for shared file access"
