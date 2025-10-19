#!/bin/bash
# Client installer for liminati.internal DNS and SSL certificate
# Usage: ./install-client.sh <server-ip>
# Or: curl http://<server-ip>:8080/liminati-ca.crt -o /tmp/liminati-ca.crt && ./install-client.sh <server-ip>

set -e

SERVER_IP="${1:-}"
CERT_FILE="/tmp/liminati-ca.crt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            echo "$ID"
        else
            echo "linux"
        fi
    else
        echo "unknown"
    fi
}

# Download certificate if server IP is provided
download_cert() {
    if [ -n "$SERVER_IP" ] && [ ! -f "$CERT_FILE" ]; then
        print_info "Downloading certificate from $SERVER_IP..."
        curl -f "http://$SERVER_IP:8081/liminati-ca.crt" -o "$CERT_FILE" || {
            print_error "Failed to download certificate from http://$SERVER_IP:8081/liminati-ca.crt"
            exit 1
        }
    elif [ ! -f "$CERT_FILE" ]; then
        print_error "Certificate file not found at $CERT_FILE"
        print_error "Usage: $0 <server-ip>"
        print_error "Or download manually: curl http://<server-ip>:8081/liminati-ca.crt -o $CERT_FILE"
        exit 1
    fi
}

# Install certificate on macOS
install_cert_macos() {
    print_info "Installing certificate to macOS System Keychain..."
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CERT_FILE"
    print_info "✓ Certificate installed successfully"

    # Configure Python to use the certificate
    print_info "Configuring Python SSL..."

    # Add SSL_CERT_FILE to shell profiles
    for profile in ~/.zshrc ~/.bashrc ~/.bash_profile; do
        if [ -f "$profile" ]; then
            # Check if already configured
            if grep -q "SSL_CERT_FILE.*liminati-ca.crt" "$profile" 2>/dev/null; then
                continue
            fi

            # Try to write to the file, skip if permission denied
            if [ -w "$profile" ]; then
                echo "" >> "$profile"
                echo "# Liminati.internal SSL certificate for Python" >> "$profile"
                echo "export SSL_CERT_FILE=\"$CERT_FILE\"" >> "$profile"
                print_info "  Added SSL_CERT_FILE to $profile"
            else
                print_warn "  Skipping $profile (no write permission)"
            fi
        fi
    done

    # For immediate effect in current session
    export SSL_CERT_FILE="$CERT_FILE"

    print_info "✓ Python SSL configured (restart terminal to apply)"
}

# Install certificate on Ubuntu/Debian
install_cert_ubuntu() {
    print_info "Installing certificate to system trust store..."
    sudo cp "$CERT_FILE" /usr/local/share/ca-certificates/liminati-ca.crt
    sudo update-ca-certificates
    print_info "✓ Certificate installed successfully"
}

# Install certificate on Fedora/RHEL/CentOS
install_cert_fedora() {
    print_info "Installing certificate to system trust store..."
    sudo cp "$CERT_FILE" /etc/pki/ca-trust/source/anchors/liminati-ca.crt
    sudo update-ca-trust
    print_info "✓ Certificate installed successfully"
}

# Install certificate on Arch Linux
install_cert_arch() {
    print_info "Installing certificate to system trust store..."
    sudo cp "$CERT_FILE" /etc/ca-certificates/trust-source/anchors/liminati-ca.crt
    sudo trust extract-compat
    print_info "✓ Certificate installed successfully"
}

# Configure DNS on macOS
configure_dns_macos() {
    if [ -z "$SERVER_IP" ]; then
        print_warn "No server IP provided, skipping DNS configuration"
        return
    fi

    print_info "Configuring DNS resolver for liminati.internal..."

    # Create resolver directory
    sudo mkdir -p /etc/resolver

    # Create resolver configuration
    echo "nameserver $SERVER_IP" | sudo tee /etc/resolver/liminati.internal > /dev/null

    print_info "✓ DNS resolver configured for liminati.internal"
    print_info "  All *.liminati.internal queries will use $SERVER_IP"
}

# Configure DNS on Linux (using systemd-resolved)
configure_dns_linux_systemd() {
    if [ -z "$SERVER_IP" ]; then
        print_warn "No server IP provided, skipping DNS configuration"
        return
    fi

    if ! command -v systemd-resolve &> /dev/null && ! command -v resolvectl &> /dev/null; then
        print_warn "systemd-resolved not found, please configure DNS manually"
        print_info "Add this to your /etc/hosts or DNS server:"
        print_info "  nameserver $SERVER_IP  # for *.liminati.internal"
        return
    fi

    print_info "Configuring systemd-resolved for liminati.internal..."

    # Create resolved.conf.d directory
    sudo mkdir -p /etc/systemd/resolved.conf.d

    # Create configuration for liminati.internal domain
    cat << EOF | sudo tee /etc/systemd/resolved.conf.d/liminati.conf > /dev/null
[Resolve]
DNS=$SERVER_IP
Domains=~liminati.internal
EOF

    sudo systemctl restart systemd-resolved

    print_info "✓ DNS configured via systemd-resolved"
    print_info "  All *.liminati.internal queries will use $SERVER_IP"
}

# Configure DNS on Linux (using NetworkManager)
configure_dns_linux_nm() {
    if [ -z "$SERVER_IP" ]; then
        print_warn "No server IP provided, skipping DNS configuration"
        return
    fi

    if ! command -v nmcli &> /dev/null; then
        print_warn "NetworkManager not found"
        configure_dns_linux_systemd
        return
    fi

    print_info "Configuring NetworkManager DNS..."

    # Get active connection
    ACTIVE_CONN=$(nmcli -t -f NAME,DEVICE connection show --active | head -n1 | cut -d: -f1)

    if [ -z "$ACTIVE_CONN" ]; then
        print_warn "No active network connection found"
        configure_dns_linux_systemd
        return
    fi

    print_info "Modifying connection: $ACTIVE_CONN"

    # Add DNS server and search domain
    sudo nmcli connection modify "$ACTIVE_CONN" +ipv4.dns "$SERVER_IP"
    sudo nmcli connection modify "$ACTIVE_CONN" ipv4.dns-search "liminati.internal"
    sudo nmcli connection modify "$ACTIVE_CONN" ipv4.ignore-auto-dns yes

    # Restart connection
    sudo nmcli connection down "$ACTIVE_CONN" && sudo nmcli connection up "$ACTIVE_CONN"

    print_info "✓ DNS configured via NetworkManager"
}

# Main installation
main() {
    print_info "Liminati.internal Client Installer"
    print_info "=================================="
    echo ""

    OS=$(detect_os)
    print_info "Detected OS: $OS"
    echo ""

    # Download certificate
    download_cert

    # Install certificate based on OS
    case "$OS" in
        macos)
            install_cert_macos
            echo ""
            configure_dns_macos
            ;;
        ubuntu|debian)
            install_cert_ubuntu
            echo ""
            configure_dns_linux_systemd
            ;;
        fedora|rhel|centos|rocky|almalinux)
            install_cert_fedora
            echo ""
            configure_dns_linux_systemd
            ;;
        arch|manjaro)
            install_cert_arch
            echo ""
            configure_dns_linux_systemd
            ;;
        *)
            print_error "Unsupported OS: $OS"
            print_info "Please install the certificate manually from: $CERT_FILE"
            exit 1
            ;;
    esac

    echo ""
    print_info "================================================"
    print_info "Installation complete!"
    print_info "================================================"
    echo ""
    print_info "IMPORTANT: Restart your terminal for Python SSL to work!"
    echo ""
    print_info "You can now access services:"
    print_info "  • Web UI:   https://webui.liminati.internal"
    print_info "  • vLLM API: https://vllm.liminati.internal"
    print_info "  • Opik:     https://opik.liminati.internal"
    echo ""
    print_info "Test DNS resolution:"
    print_info "  nslookup webui.liminati.internal"
    echo ""
    print_info "Test HTTPS connection:"
    print_info "  curl https://webui.liminati.internal"
    echo ""
    print_info "For Python/Opik to work, start a NEW terminal session!"
    echo ""
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please run as regular user (will prompt for sudo when needed)"
    exit 1
fi

main
