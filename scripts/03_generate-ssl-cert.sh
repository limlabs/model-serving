#!/bin/bash
# Generate self-signed SSL certificate for liminati.internal

set -e

SSL_DIR="/var/lib/vllm/nginx/ssl"
DIST_DIR="/var/lib/vllm/nginx/ssl/dist"
CERT_DAYS=3650  # 10 years

# Create directories
sudo mkdir -p "$SSL_DIR"
sudo mkdir -p "$DIST_DIR"

# Check if certificate already exists
if [ -f "$SSL_DIR/liminati.internal.crt" ] && [ -f "$SSL_DIR/liminati.internal.key" ]; then
    echo "SSL certificate already exists at $SSL_DIR/liminati.internal.crt"

    # Debug: Show certificate info
    echo "Checking certificate validity..."

    # Check if it's still valid for at least 30 days
    if sudo openssl x509 -checkend 2592000 -noout -in "$SSL_DIR/liminati.internal.crt" 2>/dev/null; then
        echo "Certificate is still valid for at least 30 days. Skipping generation."

        # Ensure distribution copy exists
        if [ ! -f "$DIST_DIR/liminati-ca.crt" ]; then
            sudo cp "$SSL_DIR/liminati.internal.crt" "$DIST_DIR/liminati-ca.crt"
            sudo chmod 644 "$DIST_DIR/liminati-ca.crt"
        fi

        # Detect Tailscale IP or fallback
        if command -v tailscale &> /dev/null; then
            HOST_IP=$(tailscale ip -4 2>/dev/null || hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        else
            HOST_IP=$(hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        fi
        [ -z "$HOST_IP" ] && HOST_IP=$(hostname -I | awk '{print $1}')

        echo "Certificate: $SSL_DIR/liminati.internal.crt"
        echo "Private key: $SSL_DIR/liminati.internal.key"
        echo "Client dist: $DIST_DIR/liminati-ca.crt"

        exit 0
    else
        echo "Certificate is expiring soon or invalid. Regenerating..."
    fi
fi

echo "Generating self-signed certificate for *.liminati.internal..."
sudo openssl req -x509 -nodes -days $CERT_DAYS \
    -newkey rsa:4096 \
    -keyout "$SSL_DIR/liminati.internal.key" \
    -out "$SSL_DIR/liminati.internal.crt" \
    -subj "/C=US/ST=State/L=City/O=Liminati/CN=*.liminati.internal" \
    -addext "subjectAltName=DNS:*.liminati.internal,DNS:liminati.internal"

echo "Setting permissions..."
sudo chown -R vllm-user:vllm-user "$SSL_DIR"
sudo chmod 600 "$SSL_DIR/liminati.internal.key"
sudo chmod 644 "$SSL_DIR/liminati.internal.crt"

# Create a copy for client distribution
sudo cp "$SSL_DIR/liminati.internal.crt" "$DIST_DIR/liminati-ca.crt"
sudo chmod 644 "$DIST_DIR/liminati-ca.crt"

# Detect Tailscale IP or fallback
if command -v tailscale &> /dev/null; then
    HOST_IP=$(tailscale ip -4 2>/dev/null || hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
else
    HOST_IP=$(hostname -I | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
fi
[ -z "$HOST_IP" ] && HOST_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "✓ SSL certificate generated successfully!"
echo "  Certificate: $SSL_DIR/liminati.internal.crt"
echo "  Private key: $SSL_DIR/liminati.internal.key"
echo "  Client dist: $DIST_DIR/liminati-ca.crt"
echo ""
echo "Clients can install the certificate using:"
echo "  curl http://$HOST_IP:8081/install-client.sh | bash -s $HOST_IP"