#!/bin/bash
# Generate self-signed SSL certificate for liminati.internal

set -e

SSL_DIR="/var/lib/vllm/nginx/ssl"
CERT_DAYS=3650  # 10 years

echo "Creating SSL directory..."
sudo mkdir -p "$SSL_DIR"

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
DIST_DIR="/var/lib/vllm/nginx/ssl/dist"
sudo mkdir -p "$DIST_DIR"
sudo cp "$SSL_DIR/liminati.internal.crt" "$DIST_DIR/liminati-ca.crt"
sudo chmod 644 "$DIST_DIR/liminati-ca.crt"

echo ""
echo "✓ SSL certificate generated successfully!"
echo "  Certificate: $SSL_DIR/liminati.internal.crt"
echo "  Private key: $SSL_DIR/liminati.internal.key"
echo "  Client dist: $DIST_DIR/liminati-ca.crt"
echo ""
echo "Clients can install the certificate using:"
echo "  curl http://$(hostname -I | awk '{print $1}'):8080/liminati-ca.crt | ./install-client.sh"
