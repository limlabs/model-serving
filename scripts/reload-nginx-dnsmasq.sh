#!/bin/bash
# Quick script to reload nginx and dnsmasq configurations

set -e

echo "Reloading nginx and dnsmasq configurations..."
echo ""

# Reload nginx (system service)
if sudo systemctl is-active --quiet nginx-proxy 2>/dev/null; then
    echo "Reloading nginx..."
    sudo podman exec nginx-proxy nginx -s reload 2>/dev/null || sudo systemctl restart nginx-proxy
    echo "✓ Nginx reloaded"
else
    echo "⚠ Nginx is not running"
fi

echo ""

# Restart dnsmasq (restart needed for DNS changes, system service)
if sudo systemctl is-active --quiet dnsmasq 2>/dev/null; then
    echo "Restarting dnsmasq..."
    sudo systemctl restart dnsmasq
    echo "✓ DNSmasq restarted"
else
    echo "⚠ DNSmasq is not running"
fi

echo ""
echo "Done!"
