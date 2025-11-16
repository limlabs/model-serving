# Dagster Setup with Podman Quadlets

Self-hosted Dagster orchestration platform running as rootless Podman containers managed by systemd quadlets.

## Architecture

### Components

| Service | Container | Port | Description |
|---------|-----------|------|-------------|
| Webserver | `dagster-webserver` | 3002 | Dagster web UI and GraphQL API |
| Daemon | `dagster-daemon` | - | Runs schedules, sensors, and run queue |
| PostgreSQL | `dagster-postgres` | 5432 (internal) | Storage backend for runs, events, and schedules |
| Network | `dagster` | - | Bridge network for inter-service communication |

### Directory Structure

```
/var/lib/dagster/                    # Home directory (owner: dagster-user)
├── postgres/                        # PostgreSQL data
│   └── pgdata/                      # Database files
├── dagster_home/                    # Dagster home directory
│   ├── dagster.yaml                 # Main configuration
│   ├── workspace.yaml               # Code location definitions
│   ├── storage/                     # Local artifact storage
│   ├── logs/                        # Compute logs
│   └── history/                     # Run history
├── code/                            # Your Dagster code
│   └── example_pipeline.py          # Example pipeline
└── .config/containers/systemd/      # Quadlet definitions
```

## Installation

### Prerequisites

- Podman installed
- systemd with user services support
- Sufficient disk space for PostgreSQL data

### Quick Start

```bash
cd model-serving/scripts
./setup-dagster.sh
```

This will:
1. Create `dagster-user` with proper subuid/subgid ranges
2. Set up directory structure with correct permissions
3. Copy configuration files
4. Deploy systemd quadlet files
5. Start all Dagster services

### Verify Installation

```bash
# Check service status
./dagster-manage.sh status

# View webserver logs
./dagster-manage.sh logs webserver

# Access the UI
open http://localhost:3002
# Or via HTTPS (if nginx/dnsmasq configured)
open https://dagster.liminati.internal
```

## Usage

### Management Commands

The `dagster-manage.sh` script provides convenient service management:

```bash
# View all services status
./dagster-manage.sh status

# Start/stop/restart services
./dagster-manage.sh start
./dagster-manage.sh stop webserver
./dagster-manage.sh restart daemon

# View logs (follows in real-time)
./dagster-manage.sh logs webserver
./dagster-manage.sh logs daemon

# List running containers
./dagster-manage.sh ps

# Reload systemd configuration after changes
./dagster-manage.sh reload
```

### Direct systemd Commands

```bash
# Status
sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) systemctl --user status dagster-webserver

# Logs
sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) journalctl --user -u dagster-webserver -f

# Restart
sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) systemctl --user restart dagster-webserver
```

## Development

### Adding Your Dagster Code

1. **Create your Dagster project:**

```bash
# Create a new Python file in the code directory
sudo -u dagster-user tee /var/lib/dagster/code/my_pipeline.py << 'EOF'
from dagster import asset, Definitions

@asset
def my_asset():
    return "Hello from my pipeline!"

defs = Definitions(assets=[my_asset])
EOF
```

2. **Update workspace.yaml:**

```bash
sudo -u dagster-user tee /var/lib/dagster/dagster_home/workspace.yaml << 'EOF'
load_from:
  - python_file:
      relative_path: /opt/dagster/code/my_pipeline.py
      working_directory: /opt/dagster/code
  - python_file:
      relative_path: /opt/dagster/code/example_pipeline.py
      working_directory: /opt/dagster/code
EOF
```

3. **Reload the workspace:**

```bash
./dagster-manage.sh restart webserver daemon
```

### Installing Python Dependencies

If your Dagster code requires additional Python packages:

1. **Create a requirements.txt:**

```bash
sudo -u dagster-user tee /var/lib/dagster/code/requirements.txt << 'EOF'
pandas>=2.0.0
requests>=2.31.0
EOF
```

2. **Build a custom image with dependencies:**

```bash
# Create a Dockerfile
cat > /tmp/Dockerfile.dagster << 'EOF'
FROM docker.io/dagster/dagster-celery-k8s:latest

COPY requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt
EOF

# Build the image
podman build -t localhost/dagster-custom:latest -f /tmp/Dockerfile.dagster /var/lib/dagster/code/

# Update quadlet files to use custom image
# Edit: /var/lib/dagster/.config/containers/systemd/dagster-webserver.container
# Change: Image=docker.io/dagster/dagster-celery-k8s:latest
# To:     Image=localhost/dagster-custom:latest

# Restart services
./dagster-manage.sh reload
./dagster-manage.sh restart
```

### Example Pipeline with Schedule

The included `example_pipeline.py` demonstrates:
- **Assets**: Data processing steps with dependencies
- **Jobs**: Grouping assets into executable units
- **Schedules**: Running jobs on a cron schedule

Access the UI at http://localhost:3002 to:
- View asset lineage
- Materialize assets manually
- Enable/disable schedules
- Monitor run history

## Configuration

### Dagster Configuration

Main configuration file: `/var/lib/dagster/dagster_home/dagster.yaml`

Key settings:
- **Storage**: PostgreSQL backend for all Dagster data
- **Run Launcher**: Default launcher (runs in same container)
- **Run Coordinator**: Queued coordinator for managing concurrent runs
- **Compute Logs**: Local storage for run logs
- **Telemetry**: Disabled by default

### PostgreSQL Configuration

Database credentials (defined in quadlet files):
- **User**: `dagster`
- **Password**: `dagster`
- **Database**: `dagster`
- **Host**: `dagster-postgres` (on dagster network)
- **Port**: `5432`

**Security Note**: Change the default password in production by updating:
- `/home/austin/model-serving/quadlets/dagster-postgres.container`
- `/home/austin/model-serving/quadlets/dagster-daemon.container`
- `/home/austin/model-serving/quadlets/dagster-webserver.container`

### Workspace Configuration

File: `/var/lib/dagster/dagster_home/workspace.yaml`

Defines code locations (Python files or packages) that Dagster loads. Update this file when adding new pipelines.

## Networking

### Internal Network

Services communicate via the `dagster` bridge network:
- `dagster-postgres:5432` - PostgreSQL
- `dagster-daemon` - Daemon process
- `dagster-webserver:3000` - Web UI

### External Access

- **Local HTTP**: http://localhost:3002 (mapped from container port 3000)
- **HTTPS via Nginx**: https://dagster.liminati.internal
- **GraphQL API**: Available at `/graphql` on either endpoint

### Integration with Nginx and DNSmasq

The `setup-dagster.sh` script automatically configures nginx and dnsmasq for HTTPS access.

**Nginx configuration** (`/var/lib/nginx-proxy/conf.d/dagster.conf`):
- HTTP to HTTPS redirect
- SSL termination with wildcard certificate
- WebSocket support for live updates
- Security headers (HSTS, X-Frame-Options, etc.)

**DNSmasq configuration** (`/var/lib/dnsmasq-llm/dnsmasq.conf`):
- DNS record: `dagster.liminati.internal` → Your Tailscale IP

**Manual configuration** (if needed):

```bash
# Copy nginx config
sudo cp config/nginx/conf.d/dagster.conf /var/lib/nginx-proxy/conf.d/

# Copy dnsmasq config (includes dagster.liminati.internal entry)
sudo cp config/dnsmasq/dnsmasq.conf /var/lib/dnsmasq-llm/

# Reload services (nginx and dnsmasq run as system services)
./scripts/reload-nginx-dnsmasq.sh
```

**Access via**: https://dagster.liminati.internal

## Troubleshooting

### Services Won't Start

```bash
# Check if dagster-user can run podman
sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) podman ps

# Check systemd logs
./dagster-manage.sh logs webserver

# Verify network exists
sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) podman network ls
```

### Database Connection Issues

```bash
# Check if PostgreSQL is running
./dagster-manage.sh status postgres

# Test database connection
sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) \
  podman exec dagster-postgres psql -U dagster -d dagster -c '\dt'

# View PostgreSQL logs
./dagster-manage.sh logs postgres
```

### Workspace Not Loading

```bash
# Check workspace.yaml syntax
cat /var/lib/dagster/dagster_home/workspace.yaml

# Verify code files exist
ls -la /var/lib/dagster/code/

# Check daemon logs for errors
./dagster-manage.sh logs daemon

# Restart to reload workspace
./dagster-manage.sh restart
```

### Permission Issues

```bash
# Verify ownership
sudo ls -la /var/lib/dagster/

# Fix permissions if needed
sudo chown -R dagster-user:dagster-user /var/lib/dagster/
```

### Runs Failing

```bash
# Check compute logs in UI or directly
sudo -u dagster-user cat /var/lib/dagster/dagster_home/logs/<run_id>/compute_logs/*

# Check daemon is running
./dagster-manage.sh status daemon

# Verify run launcher configuration
sudo -u dagster-user cat /var/lib/dagster/dagster_home/dagster.yaml
```

## Backup and Restore

### Backup

```bash
# Stop services
./dagster-manage.sh stop

# Backup PostgreSQL data
sudo tar -czf dagster-backup-$(date +%Y%m%d).tar.gz \
  -C /var/lib/dagster postgres dagster_home code

# Restart services
./dagster-manage.sh start
```

### Restore

```bash
# Stop services
./dagster-manage.sh stop

# Restore from backup
sudo tar -xzf dagster-backup-YYYYMMDD.tar.gz -C /var/lib/dagster

# Fix permissions
sudo chown -R dagster-user:dagster-user /var/lib/dagster/

# Restart services
./dagster-manage.sh start
```

## Upgrading

To upgrade Dagster to a newer version:

```bash
# Stop services
./dagster-manage.sh stop

# Pull new images
sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) \
  podman pull docker.io/dagster/dagster-celery-k8s:latest

# Restart services
./dagster-manage.sh start

# Check version in UI: Help -> About
```

## Advanced Configuration

### Enabling Celery Executor

For distributed execution across multiple workers:

1. Add Redis and Celery worker containers
2. Update `dagster.yaml` to use CeleryK8sRunLauncher
3. Configure worker pools and queues

### Integrating with External Services

Dagster can connect to:
- **S3/MinIO**: For artifact storage
- **Slack**: For notifications
- **dbt**: For data transformations
- **Great Expectations**: For data quality
- **External databases**: As I/O managers

Configure via environment variables in quadlet files or resources in your Dagster code.

## Resources

- **Dagster Docs**: https://docs.dagster.io/
- **Dagster GitHub**: https://github.com/dagster-io/dagster
- **Podman Quadlets**: https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html

## Security Notes

- **User Isolation**: Runs as dedicated `dagster-user` with no sudo access
- **Rootless Containers**: All containers run in user namespace
- **Network Isolation**: Services communicate via dedicated bridge network
- **Default Credentials**: Change PostgreSQL password in production
- **File Permissions**: All files owned by `dagster-user` only

## License

MIT
