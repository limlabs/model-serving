# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a model serving infrastructure that provides secure, multi-user architecture for running vLLM with nginx reverse proxy, Open WebUI, Opik (LLM observability), and DNS services on a Tailscale network. The system uses rootless Podman containers with systemd quadlets for service management.

## Architecture

### Core Components
- **vLLM**: OpenAI-compatible LLM API server (port 8000)
- **Open WebUI**: ChatGPT-like web interface (port 3000)
- **Opik**: LLM observability and tracing platform (port 5173)
  - MySQL, Redis, ClickHouse, Zookeeper, MinIO (infrastructure)
  - Backend API, Python evaluator backend, Frontend UI
- **Nginx**: Reverse proxy with SSL termination (ports 80, 443, 8081)
- **DNSmasq**: DNS server for `*.liminati.internal` domain (port 53, 5380)

### Security Model
- Each service runs as a dedicated unprivileged user
- Rootless containers via Podman
- No shared files between services
- SSL termination at nginx with self-signed certificates

### Directory Layout
```
/var/lib/
├── nginx-proxy/     (nginx-user)
├── dnsmasq-llm/     (dnsmasq-user)
├── vllm/            (vllm-user)
├── webui/           (webui-user)
└── opik/            (opik-user)
    ├── mysql/       (MySQL database)
    ├── clickhouse/  (ClickHouse analytics DB)
    ├── zookeeper/   (ZooKeeper for ClickHouse)
    ├── minio/       (Object storage)
    └── config/      (Opik configuration files)
```

## Key Commands

### Installation & Setup

**CRITICAL: install-quadlets.sh MUST BE IDEMPOTENT**

The installation script is designed to be run multiple times safely without breaking the system. It MUST:
- Handle missing files/directories gracefully (don't fail on chown of non-existent files)
- Clean up corrupted podman storage before fixing ownership
- Skip operations that would fail due to transient issues
- Use `|| true` or `2>/dev/null || true` to prevent failures from breaking the entire script
- Properly stop services before cleanup to avoid file locks
- Handle both old and new naming conventions (e.g., opik pod vs opik-infra pod)

When modifying this script, always ensure every operation can be safely repeated.

```bash
# Full installation (idempotent - safe to run multiple times)
./scripts/install-quadlets.sh

# Client setup on remote machines
curl http://<tailscale-ip>:8081/install-client.sh | bash -s <tailscale-ip>
```

### Service Management
```bash
# Check service status (for any service: nginx-proxy, vllm-qwen, open-webui, opik, dnsmasq)
sudo -u <service-user> XDG_RUNTIME_DIR=/run/user/$(id -u <service-user>) systemctl --user status <service-name>

# View logs
sudo -u <service-user> XDG_RUNTIME_DIR=/run/user/$(id -u <service-user>) journalctl --user -u <service-name> -f

# Restart service
sudo -u <service-user> XDG_RUNTIME_DIR=/run/user/$(id -u <service-user>) systemctl --user restart <service-name>

# vLLM-specific management
./scripts/vllm-manage.sh status|logs|restart|reconfigure

# Opik-specific management
./scripts/opik-manage.sh status|logs|restart|health|mysql-shell|clickhouse-shell
```

### Testing & Verification
```bash
# Test DNS resolution
nslookup webui.liminati.internal <tailscale-ip>
nslookup opik.liminati.internal <tailscale-ip>

# Check vLLM health
curl http://localhost:8000/health

# Check Opik health
curl http://localhost:5173/
curl http://localhost:8080/health-check

# Check nginx status
curl -k https://vllm.liminati.internal/health
curl -k https://opik.liminati.internal/
```

## Important Files

### Scripts
- `scripts/install-quadlets.sh` - Main installer, creates users, directories, SSL certs, deploys quadlets
- `scripts/vllm-manage.sh` - vLLM/WebUI management utility
- `scripts/opik-manage.sh` - Opik management utility (pod, containers, databases)
- `scripts/generate-ssl-cert.sh` - SSL certificate generation
- `scripts/install-client.sh` - Client-side setup script

### Quadlets (Systemd Service Definitions)
- `quadlets/vllm-qwen.container` - vLLM container configuration
- `quadlets/open-webui.container` - Open WebUI container configuration
- `quadlets/nginx-proxy.container` - Nginx reverse proxy configuration
- `quadlets/dnsmasq.container` - DNSmasq DNS server configuration
- `quadlets/opik.pod` - Opik pod definition (contains all Opik containers)
- `quadlets/opik-*.container` - Opik service containers (mysql, redis, clickhouse, zookeeper, minio, backend, python-backend, frontend)

### Configuration
- `config/nginx/nginx.conf` - Main nginx configuration
- `config/nginx/conf.d/*.conf` - Virtual host configurations (vllm, webui, opik)
- `config/dnsmasq/dnsmasq.conf` - DNSmasq configuration
- `config/opik/` - Opik configuration files (nginx, fluent-bit, clickhouse)

## Development Notes

### Script Idempotency Requirements

**ALL scripts in this repository MUST be idempotent**. This means they can be run multiple times without causing errors or breaking the system.

Key principles:
1. **Never assume files exist** - Always check before accessing or use `|| true`
2. **Clean up corrupted state** - Remove broken podman storage, stale locks, etc.
3. **Handle in-use resources** - Stop services before cleanup, handle locked files
4. **Suppress non-critical errors** - Use `2>/dev/null || true` for operations that may fail
5. **Support version transitions** - Handle both old and new naming (e.g., old pod name vs new pod name)

Example idempotent patterns:
```bash
# Good - won't fail if file doesn't exist
sudo chown -R user:user /path 2>/dev/null || true

# Good - creates only if missing
sudo mkdir -p /path

# Good - removes corrupted files before fixing ownership
find /path -type f 2>/dev/null | while read f; do
    sudo chown user:user "$f" 2>/dev/null || sudo rm -f "$f"
done

# Bad - fails if file is missing
sudo chown -R user:user /path
```

### Adding New Services
1. Create a dedicated user for the service
2. Set up directory structure under `/var/lib/<service-name>/`
3. Create a quadlet file in `quadlets/`
4. **Add DNS record** to `config/dnsmasq/dnsmasq.conf` if the service needs a friendly hostname
5. Update nginx configuration if web-accessible (add virtual host in `config/nginx/conf.d/`)
6. Update `install-quadlets.sh` with new user/directories
7. Ensure all operations are idempotent
8. Deploy via `install-quadlets.sh`

### Modifying Existing Services
- Edit quadlet files in `quadlets/` directory
- Run `install-quadlets.sh` to deploy changes (idempotent - safe to run multiple times)
- Use `systemctl --user daemon-reload` after quadlet changes
- Test by running `install-quadlets.sh` multiple times in succession

### SSL Certificates
- Wildcard cert for `*.liminati.internal`
- Generated by `generate-ssl-cert.sh`
- Stored in `/var/lib/nginx-proxy/ssl/`
- Private key permissions: 640, owned by nginx-user

### Debugging Services
- All services run as systemd user units
- Must use `sudo -u <user> XDG_RUNTIME_DIR=/run/user/$(id -u <user>)` prefix
- Check podman directly: `sudo -u <user> podman ps`
- Service logs in journalctl: `journalctl --unit=user@<uid>.service`

## Service Access Points
- Web UI: https://webui.liminati.internal
- vLLM API: https://vllm.liminati.internal
- Opik: https://opik.liminati.internal (or http://<tailscale-ip>:5173)
- DNS Admin: http://<tailscale-ip>:5380
- Client installer: http://<tailscale-ip>:8081/install-client.sh
- MinIO Console: http://<tailscale-ip>:9090 (credentials in opik-manage.sh)

## Opik LLM Observability Platform

Opik provides comprehensive LLM observability, including tracing, evaluation, and monitoring for AI applications.

### Architecture
Opik runs as a **podman pod** with 9 containers:
1. **opik-mysql** - State database (MySQL 8.4)
2. **opik-redis** - Cache and message broker
3. **opik-zookeeper** - Coordination service for ClickHouse
4. **opik-clickhouse** - Analytics database for traces/metrics
5. **opik-minio** - Object storage (S3-compatible)
6. **opik-minio-init** - One-shot bucket initialization
7. **opik-backend** - Main Java API server (port 8080)
8. **opik-python-backend** - Python evaluator service (port 8000)
9. **opik-frontend** - Nginx + React UI (port 5173)

### Management Commands
```bash
# Service status and container info
./scripts/opik-manage.sh status

# View logs for specific container
./scripts/opik-manage.sh logs backend 200
./scripts/opik-manage.sh follow frontend

# Check health of all endpoints
./scripts/opik-manage.sh health

# Database access
./scripts/opik-manage.sh mysql-shell
./scripts/opik-manage.sh clickhouse-shell
./scripts/opik-manage.sh redis-cli
./scripts/opik-manage.sh minio-console

# Restart entire pod
./scripts/opik-manage.sh restart

# Reinstall all quadlets
./scripts/opik-manage.sh reinstall
```

### Data Persistence
All Opik data is stored in `/var/lib/opik/`:
- `mysql/` - MySQL state database
- `clickhouse/data/` - ClickHouse analytics data
- `clickhouse/logs/` - ClickHouse logs
- `clickhouse/config/` - ClickHouse configuration
- `zookeeper/` - ZooKeeper data
- `minio/` - Object storage data

### Integration with vLLM
To trace vLLM requests through Opik:
1. Configure your application to use Opik's Python SDK
2. Point traces to `https://opik.liminati.internal/api` or `http://localhost:5173/api`
3. Use Opik UI to view traces, metrics, and evaluations

### Default Credentials
- MySQL: `opik/opik` (database: `opik`)
- Redis: password `opik`
- ClickHouse: `opik/opik` (database: `opik`)
- MinIO: `THAAIOSFODNN7EXAMPLE` / `LESlrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`

**Note:** Change these credentials for production use by modifying the quadlet files.