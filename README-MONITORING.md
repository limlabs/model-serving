# Monitoring Stack Setup

This repository includes a complete monitoring stack using Grafana and Prometheus, deployed as rootless Podman quadlets.

## Components

- **Prometheus**: Time-series database that scrapes and stores metrics
- **Grafana**: Visualization and dashboards for metrics
- **Node Exporter**: System-level metrics (CPU, memory, disk, network)

## Architecture

```
                  ┌──────────────────┐
                  │  Nginx Proxy     │
                  │  (SSL/TLS)       │
                  │  :443            │
                  └────────┬─────────┘
                           │
              ┌────────────┴─────────────┐
              │                          │
              ▼                          ▼
    grafana.liminati.internal   vllm.liminati.internal
              │                          │
┌─────────────▼───────┐       ┌──────────▼──────┐
│      Grafana        │       │      vLLM       │
│   (Dashboard)       │       │   :8000/metrics │
│      :3000          │       └─────────────────┘
└──────────┬──────────┘
           │
           │ Queries
           ▼
┌──────────────────┐
│   Prometheus     │ :9090
│  (Metrics DB)    │
└────────┬─────────┘
         │
         │ Scrapes
         ├─────────────────┬──────────────┐
         ▼                 ▼              ▼
┌────────────────┐  ┌─────────────┐  ┌──────────────┐
│     vLLM       │  │    Node     │  │  Prometheus  │
│  :8000/metrics │  │  Exporter   │  │    :9090     │
│                │  │    :9100    │  │  (self)      │
└────────────────┘  └─────────────┘  └──────────────┘
```

## Metrics Being Collected

### vLLM Metrics (from :8000/metrics)
- `vllm:num_requests_running` - Number of requests currently running
- `vllm:num_requests_waiting` - Number of requests waiting
- `vllm:e2e_request_latency_seconds` - End-to-end request latency
- `vllm:gpu_cache_usage_perc` - GPU cache utilization
- `vllm:request_prompt_tokens` - Request prompt length
- `vllm:request_generation_tokens` - Request generation length

### System Metrics (from Node Exporter)
- CPU usage, load average
- Memory usage
- Disk I/O and space
- Network traffic
- And many more system-level metrics

## Installation

### Quick Setup

1. Clone the repository to your home directory:
   ```bash
   cd ~
   git clone <repository-url> model-serving
   cd model-serving
   ```

2. Run the setup script:
   ```bash
   ./scripts/setup-monitoring.sh
   ```

### Manual Setup

1. Create required directories:
   ```bash
   mkdir -p ~/model-serving/config/prometheus/data
   mkdir -p ~/model-serving/config/grafana/data
   ```

2. Copy quadlet files:
   ```bash
   mkdir -p ~/.config/containers/systemd
   cp ~/model-serving/quadlets/prometheus.container ~/.config/containers/systemd/
   cp ~/model-serving/quadlets/grafana.container ~/.config/containers/systemd/
   cp ~/model-serving/quadlets/node-exporter.container ~/.config/containers/systemd/
   ```

3. Reload and start services:
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now prometheus.service
   systemctl --user enable --now node-exporter.service
   systemctl --user enable --now grafana.service
   ```

## Access

### Via HTTPS (Nginx Proxy)

- **Grafana**: https://grafana.liminati.internal
  - Default username: `admin`
  - Default password: `admin`
  - You'll be prompted to change the password on first login
  - Accessible with valid SSL certificate via nginx-proxy

### Direct Access (localhost)

- **Grafana**: http://localhost:3000
- **Prometheus**: http://localhost:9090
  - Query interface and basic metrics browser
- **Node Exporter**: http://localhost:9100/metrics
  - Raw metrics endpoint

**Note**: The nginx-proxy provides SSL termination and uses the `liminati.internal` wildcard certificate. Make sure you have the DNS entry for `grafana.liminati.internal` pointing to your server (via dnsmasq or your DNS provider).

## Grafana Setup

### 1. Add Prometheus Data Source

1. Log into Grafana at http://localhost:3000
2. Click on the gear icon (⚙️) and select "Data Sources"
3. Click "Add data source"
4. Select "Prometheus"
5. Configure:
   - **Name**: Prometheus
   - **URL**: `http://localhost:9090`
   - Leave other settings as default
6. Click "Save & Test" - you should see "Data source is working"

### 2. Create Dashboards

#### Option A: Import Pre-built Dashboard

Search for vLLM dashboards on [Grafana Dashboard Repository](https://grafana.com/grafana/dashboards/):
1. Go to Dashboards > Import
2. Enter a dashboard ID or upload JSON
3. Select your Prometheus data source

#### Option B: Create Custom Dashboard

1. Click "+" icon and select "Dashboard"
2. Click "Add new panel"
3. Example queries for vLLM metrics:
   ```promql
   # Requests running
   vllm:num_requests_running

   # Request rate
   rate(vllm:request_success_total[5m])

   # P95 latency
   histogram_quantile(0.95, rate(vllm:e2e_request_latency_seconds_bucket[5m]))

   # GPU cache usage
   vllm:gpu_cache_usage_perc
   ```

4. Example queries for system metrics:
   ```promql
   # CPU usage
   100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

   # Memory usage
   (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

   # Disk usage
   (1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})) * 100
   ```

## Managing Services

### Check Status
```bash
systemctl --user status prometheus.service
systemctl --user status grafana.service
systemctl --user status node-exporter.service
```

### View Logs
```bash
journalctl --user -u prometheus.service -f
journalctl --user -u grafana.service -f
journalctl --user -u node-exporter.service -f
```

### Restart Services
```bash
systemctl --user restart prometheus.service
systemctl --user restart grafana.service
systemctl --user restart node-exporter.service
```

### Stop Services
```bash
systemctl --user stop prometheus.service
systemctl --user stop grafana.service
systemctl --user stop node-exporter.service
```

## Configuration

### Prometheus Configuration

Edit [config/prometheus/prometheus.yml](config/prometheus/prometheus.yml) to add more scrape targets or modify scrape intervals.

After editing, restart Prometheus:
```bash
systemctl --user restart prometheus.service
```

### Grafana Configuration

Grafana stores its configuration in the persistent volume at `~/model-serving/config/grafana/data`. You can also configure via environment variables in [quadlets/grafana.container](quadlets/grafana.container).

## Troubleshooting

### Services won't start
```bash
# Check for errors
journalctl --user -u prometheus.service -n 50
journalctl --user -u grafana.service -n 50

# Verify quadlet files are valid
ls -la ~/.config/containers/systemd/

# Reload systemd
systemctl --user daemon-reload
```

### Can't access metrics from vLLM
```bash
# Verify vLLM is running and exposing metrics
curl http://localhost:8000/metrics

# Check if Prometheus can reach vLLM
systemctl --user status vllm-qwen.service
```

### Grafana can't connect to Prometheus
```bash
# Verify Prometheus is accessible
curl http://localhost:9090/-/healthy

# Check Grafana logs
journalctl --user -u grafana.service -f
```

### Permission issues
```bash
# Ensure data directories exist and have proper permissions
ls -la ~/model-serving/config/prometheus/
ls -la ~/model-serving/config/grafana/

# Fix permissions
chmod 755 ~/model-serving/config/prometheus/data
chmod 755 ~/model-serving/config/grafana/data
```

## Network Configuration

All services run on the host network (`Network=host`) to allow easy communication:
- Grafana → Prometheus (port 9090)
- Prometheus → vLLM (port 8000)
- Prometheus → Node Exporter (port 9100)

This is suitable for a single-machine setup. For multi-machine setups, consider using Podman pods or networks.

## Security Notes

- The default Grafana password is `admin`. Change it immediately after first login.
- Services are running as rootless Podman containers (user-level systemd services).
- Grafana is exposed via nginx-proxy with HTTPS at `https://grafana.liminati.internal`
- The nginx configuration includes security headers (HSTS, X-Frame-Options, etc.)
- The wildcard SSL certificate for `*.liminati.internal` is used for secure access

## Nginx Proxy Configuration

Grafana is pre-configured to work with the nginx-proxy setup. The configuration file is included at:
- [config/nginx/conf.d/grafana.conf](config/nginx/conf.d/grafana.conf)

The nginx configuration:
- Redirects HTTP to HTTPS
- Terminates SSL/TLS with the `liminati.internal` wildcard certificate
- Proxies to Grafana on localhost:3000
- Includes WebSocket support for live dashboard updates
- Adds security headers

After deploying, make sure to:
1. Reload nginx to pick up the new configuration:
   ```bash
   sudo systemctl reload nginx-proxy.service
   ```

2. Ensure DNS resolution for `grafana.liminati.internal`:
   - If using dnsmasq (as configured in this repo), it should automatically resolve `*.liminati.internal`
   - Otherwise, add an entry to your DNS server or `/etc/hosts`

## Resources

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [vLLM Metrics Documentation](https://docs.vllm.ai/en/latest/design/metrics.html)
- [Node Exporter](https://github.com/prometheus/node_exporter)
