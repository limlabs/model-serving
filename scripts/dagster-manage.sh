#!/bin/bash
# Management script for Dagster services

DAGSTER_USER="dagster-user"
RUNTIME_DIR="/run/user/$(id -u $DAGSTER_USER)"

# Function to run systemctl commands as dagster-user
run_systemctl() {
    sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$RUNTIME_DIR systemctl --user "$@"
}

# Function to run journalctl commands as dagster-user
run_journalctl() {
    sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$RUNTIME_DIR journalctl --user "$@"
}

# Function to run podman commands as dagster-user
run_podman() {
    sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$RUNTIME_DIR podman "$@"
}

show_usage() {
    cat << EOF
Dagster Management Script

Usage: $0 <command> [service]

Commands:
    status [service]    - Show status of Dagster services
    start [service]     - Start Dagster services
    stop [service]      - Stop Dagster services
    restart [service]   - Restart Dagster services
    logs [service]      - Show logs for Dagster services (follows)
    ps                  - Show running containers
    reload              - Reload systemd configuration

Services:
    webserver          - Dagster web UI
    daemon             - Dagster daemon (schedules/sensors)
    postgres           - PostgreSQL database
    network            - Dagster network
    all (default)      - All services

Examples:
    $0 status                    # Status of all services
    $0 status webserver          # Status of webserver only
    $0 logs daemon               # Follow daemon logs
    $0 restart webserver         # Restart webserver
    $0 ps                        # Show running containers

EOF
}

get_service_name() {
    local service=$1
    case $service in
        webserver)
            echo "dagster-webserver.service"
            ;;
        daemon)
            echo "dagster-daemon.service"
            ;;
        postgres)
            echo "dagster-postgres.service"
            ;;
        network)
            echo "dagster-network-network.service"
            ;;
        all|"")
            echo "dagster-webserver.service dagster-daemon.service dagster-postgres.service dagster-network-network.service"
            ;;
        *)
            echo "Unknown service: $service" >&2
            echo "Valid services: webserver, daemon, postgres, network, all" >&2
            exit 1
            ;;
    esac
}

cmd_status() {
    local service=$1
    local services=$(get_service_name "$service")
    
    echo "Dagster Service Status:"
    echo "======================="
    for svc in $services; do
        echo ""
        run_systemctl status "$svc"
    done
}

cmd_start() {
    local service=$1
    local services=$(get_service_name "$service")
    
    echo "Starting Dagster services..."
    for svc in $services; do
        echo "Starting $svc..."
        run_systemctl start "$svc"
    done
    echo "✓ Services started"
}

cmd_stop() {
    local service=$1
    local services=$(get_service_name "$service")
    
    echo "Stopping Dagster services..."
    # Reverse order for stopping
    for svc in $(echo $services | tac -s ' '); do
        echo "Stopping $svc..."
        run_systemctl stop "$svc"
    done
    echo "✓ Services stopped"
}

cmd_restart() {
    local service=$1
    local services=$(get_service_name "$service")
    
    echo "Restarting Dagster services..."
    for svc in $services; do
        echo "Restarting $svc..."
        run_systemctl restart "$svc"
    done
    echo "✓ Services restarted"
}

cmd_logs() {
    local service=${1:-webserver}
    local service_name=$(get_service_name "$service" | awk '{print $1}')
    
    echo "Following logs for $service_name (Ctrl+C to exit)..."
    run_journalctl -u "$service_name" -f
}

cmd_ps() {
    echo "Running Dagster containers:"
    echo "==========================="
    run_podman ps --filter "name=dagster"
}

cmd_reload() {
    echo "Reloading systemd configuration..."
    run_systemctl daemon-reload
    echo "✓ Configuration reloaded"
}

# Main command dispatcher
case "${1:-}" in
    status)
        cmd_status "${2:-all}"
        ;;
    start)
        cmd_start "${2:-all}"
        ;;
    stop)
        cmd_stop "${2:-all}"
        ;;
    restart)
        cmd_restart "${2:-all}"
        ;;
    logs)
        cmd_logs "${2:-webserver}"
        ;;
    ps)
        cmd_ps
        ;;
    reload)
        cmd_reload
        ;;
    help|--help|-h)
        show_usage
        ;;
    "")
        show_usage
        exit 1
        ;;
    *)
        echo "Unknown command: $1"
        echo ""
        show_usage
        exit 1
        ;;
esac
