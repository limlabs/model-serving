# Model Serving Infrastructure

Secure, multi-user architecture for running vLLM with nginx reverse proxy, Open WebUI, and DNS services on a Tailscale network.

## Architecture

### Security Model
- **User Isolation**: Each service runs as its own unprivileged user with dedicated home directory
- **No Shared Files**: Each service owns and accesses only its own files
- **Rootless Containers**: All containers run without root privileges
- **SSL Termination**: Nginx handles HTTPS with self-signed certificates

### Services

| Service | User | Port(s) | Description |
|---------|------|---------|-------------|
| vLLM | `vllm-user` | 8000 | OpenAI-compatible LLM API |
| Open WebUI | `webui-user` | 3000 | Web interface for vLLM |
| Nginx | `nginx-user` | 80, 443, 8081 | Reverse proxy with SSL |
| DNSmasq | `dnsmasq-user` | 53, 5380 | DNS server for `*.liminati.internal` |

### Directory Structure

```
/var/lib/
├── nginx-proxy/           # Nginx service (owner: nginx-user)
│   ├── nginx.conf
│   ├── conf.d/            # Virtual host configs
│   ├── dist/              # Client installer scripts
│   ├── ssl/               # SSL certificates
│   │   ├── liminati.internal.crt
│   │   ├── liminati.internal.key
│   │   └── dist/liminati-ca.crt
│   └── .config/containers/systemd/
├── dnsmasq-llm/           # DNSmasq service (owner: dnsmasq-user)
│   ├── dnsmasq.conf
│   └── .config/containers/systemd/
├── vllm/                  # vLLM service (owner: vllm-user)
│   ├── .cache/huggingface
│   └── .config/containers/systemd/
└── webui/                 # WebUI service (owner: webui-user)
    ├── data/
    └── .config/containers/systemd/
```

## Installation

### Prerequisites
- Ubuntu/Debian Linux
- Podman installed
- Tailscale installed and connected
- NVIDIA GPU (for vLLM)

### Quick Start

```bash
cd model-serving/scripts

# Install everything (idempotent, safe to re-run)
./install-quadlets.sh
```

This will:
1. Create dedicated users for each service
2. Set up directory structure with proper permissions
3. Generate self-signed SSL certificates
4. Deploy systemd quadlet files
5. Start all services

### Configuration

After installation, configure Tailscale DNS:
1. Go to Tailscale admin console
2. DNS → Nameservers → Add nameserver: `<your-tailscale-ip>`
3. Search domains → Add: `liminati.internal`

### Client Setup

On any machine in your Tailscale network:

```bash
curl http://<tailscale-ip>:8081/install-client.sh | bash -s <tailscale-ip>
```

This automatically:
- Installs the SSL certificate to system trust store
- Configures DNS resolver for `*.liminati.internal`

## Usage

### Access Services

Once configured, services are available at:
- **Web UI**: https://webui.liminati.internal
- **vLLM API**: https://vllm.liminati.internal
- **DNS Admin**: http://<tailscale-ip>:5380

### Manage Services

Check service status:
```bash
# Nginx
sudo -u nginx-user XDG_RUNTIME_DIR=/run/user/$(id -u nginx-user) systemctl --user status nginx-proxy

# vLLM
sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/$(id -u vllm-user) systemctl --user status vllm-qwen

# WebUI
sudo -u webui-user XDG_RUNTIME_DIR=/run/user/$(id -u webui-user) systemctl --user status open-webui

# DNSmasq
sudo -u dnsmasq-user XDG_RUNTIME_DIR=/run/user/$(id -u dnsmasq-user) systemctl --user status dnsmasq
```

View logs:
```bash
# Example: nginx logs
sudo -u nginx-user XDG_RUNTIME_DIR=/run/user/$(id -u nginx-user) journalctl --user -u nginx-proxy -f
```

Restart a service:
```bash
# Example: restart nginx
sudo -u nginx-user XDG_RUNTIME_DIR=/run/user/$(id -u nginx-user) systemctl --user restart nginx-proxy
```

## Files

### Scripts
- `install-quadlets.sh` - Main installation script
- `generate-ssl-cert.sh` - Generate SSL certificates (called by installer)
- `install-client.sh` - Client-side installer for DNS and SSL trust
- `vllm-manage.sh` - Management utility for vLLM service

### Quadlets
- `quadlets/vllm-qwen.container` - vLLM service definition
- `quadlets/open-webui.container` - Open WebUI service definition
- `quadlets/nginx-proxy.container` - Nginx reverse proxy definition
- `quadlets/dnsmasq.container` - DNSmasq DNS server definition

### Configs
- `config/nginx/nginx.conf` - Main nginx configuration
- `config/nginx/conf.d/*.conf` - Virtual host configurations
- `config/dnsmasq/dnsmasq.conf` - DNSmasq configuration

## Security Notes

### SSL Certificates
- Self-signed wildcard certificate for `*.liminati.internal`
- 10-year validity
- Private key only readable by `nginx-user` (640 permissions)
- Client installer adds certificate to system trust store

### User Isolation
- Each service runs as a dedicated unprivileged user
- No service has sudo access
- Containers are rootless (run in user namespaces)
- Each service owns only its own files, no cross-service file access

### Network Security
- All services use Tailscale network (not exposed to internet)
- DNS only resolves `*.liminati.internal` queries
- Nginx enforces HTTPS with HSTS headers

## Troubleshooting

### Service won't start
```bash
# Check if user can run podman
sudo -u nginx-user XDG_RUNTIME_DIR=/run/user/$(id -u nginx-user) podman ps

# Check systemd logs
sudo -u nginx-user XDG_RUNTIME_DIR=/run/user/$(id -u nginx-user) journalctl --user -xeu nginx-proxy
```

### DNS not resolving
```bash
# Test DNS directly
nslookup webui.liminati.internal <tailscale-ip>

# Check dnsmasq logs
sudo -u dnsmasq-user XDG_RUNTIME_DIR=/run/user/$(id -u dnsmasq-user) journalctl --user -u dnsmasq -f
```

### SSL certificate errors
```bash
# Regenerate certificate
sudo rm -rf /var/lib/nginx-proxy/ssl/*
./install-quadlets.sh  # Will regenerate on next run
```

## License

MIT
