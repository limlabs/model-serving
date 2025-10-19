#!/bin/bash
# Opik Service Management Script

OPIK_USER="opik-user"
OPIK_UID=$(id -u $OPIK_USER 2>/dev/null)
POD_NAME="opik"
SERVICE_NAME="opik.service"

# Helper function to run commands as opik-user
run_as_opik() {
    cd /tmp && sudo su -s /bin/sh $OPIK_USER -c "XDG_RUNTIME_DIR=/run/user/$OPIK_UID $*"
}

case "$1" in
    status)
        echo "=== Opik Pod Status ==="
        run_as_opik "systemctl --user status $SERVICE_NAME"
        echo ""
        echo "=== Pod Info ==="
        run_as_opik "podman pod ps --filter name=$POD_NAME"
        echo ""
        echo "=== Container Status ==="
        run_as_opik "podman ps --filter pod=$POD_NAME --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
        ;;

    logs)
        CONTAINER=${2:-backend}
        LINES=${3:-100}
        echo "=== Opik $CONTAINER Logs (last $LINES lines) ==="
        run_as_opik "podman logs --tail $LINES opik-$CONTAINER"
        ;;

    follow)
        CONTAINER=${2:-backend}
        echo "=== Following opik-$CONTAINER logs (Ctrl+C to exit) ==="
        run_as_opik "podman logs -f opik-$CONTAINER"
        ;;

    restart)
        echo "Restarting Opik pod..."
        run_as_opik "systemctl --user restart $SERVICE_NAME"
        echo "Done. Check status with: $0 status"
        ;;

    stop)
        echo "Stopping Opik pod..."
        run_as_opik "systemctl --user stop $SERVICE_NAME"
        ;;

    start)
        echo "Starting Opik pod..."
        run_as_opik "systemctl --user start $SERVICE_NAME"
        ;;

    health)
        echo "=== Checking Opik health endpoints ==="
        echo ""
        echo "Frontend (nginx):"
        curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:5173/ || echo "Frontend not responding"
        echo ""
        echo "Backend API:"
        curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:8080/health-check || echo "Backend not responding"
        echo ""
        echo "Python Backend:"
        curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:8000/healthcheck || echo "Python backend not responding"
        echo ""
        echo "MinIO:"
        curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:9000/minio/health/live || echo "MinIO not responding"
        echo ""
        echo "ClickHouse:"
        curl -s http://localhost:8123/ping || echo "ClickHouse not responding"
        ;;

    ps)
        echo "=== All Opik Containers ==="
        run_as_opik "podman ps --filter pod=$POD_NAME --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
        ;;

    shell)
        echo "Opening shell as $OPIK_USER..."
        echo "Run 'podman pod ps' or 'podman ps --filter pod=$POD_NAME'"
        cd /tmp && sudo su -s /bin/bash $OPIK_USER
        ;;

    exec)
        shift
        run_as_opik "$*"
        ;;

    mysql-shell)
        echo "=== Connecting to MySQL ==="
        run_as_opik "podman exec -it opik-mysql mysql -uopik -popik opik"
        ;;

    clickhouse-shell)
        echo "=== Connecting to ClickHouse ==="
        run_as_opik "podman exec -it opik-clickhouse clickhouse-client --user=opik --password=opik --database=opik"
        ;;

    redis-cli)
        echo "=== Connecting to Redis ==="
        run_as_opik "podman exec -it opik-redis redis-cli -a opik"
        ;;

    minio-console)
        echo "=== MinIO Console ==="
        echo "Open http://localhost:9090 in your browser"
        echo "Username: THAAIOSFODNN7EXAMPLE"
        echo "Password: LESlrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        ;;

    reinstall)
        echo "Reinstalling Opik quadlets..."
        REPO_ROOT="$(dirname "$0")/.."
        sudo mkdir -p /var/lib/opik/.config/containers/systemd

        for quadlet in opik.pod opik-mysql.container opik-redis.container \
                       opik-zookeeper.container opik-clickhouse.container \
                       opik-minio.container opik-minio-init.container \
                       opik-backend.container opik-python-backend.container \
                       opik-frontend.container; do
            sudo cp "$REPO_ROOT/quadlets/$quadlet" /var/lib/opik/.config/containers/systemd/
        done

        sudo chown -R opik-user:opik-user /var/lib/opik/.config
        run_as_opik "systemctl --user daemon-reload"
        run_as_opik "systemctl --user restart $SERVICE_NAME"
        echo "Done. Check status with: $0 status"
        ;;

    clean)
        echo "WARNING: This will remove all Opik data!"
        echo "Press Ctrl+C within 5 seconds to cancel..."
        sleep 5
        echo "Stopping and removing Opik pod..."
        run_as_opik "systemctl --user stop $SERVICE_NAME"
        run_as_opik "podman pod rm -f $POD_NAME"
        echo "Removing data directories..."
        sudo rm -rf /var/lib/opik/{mysql,clickhouse,zookeeper,minio}/*
        echo "Done. Start with: $0 start"
        ;;

    *)
        echo "Opik Service Management Script"
        echo ""
        echo "Usage: $0 {command} [args]"
        echo ""
        echo "Commands:"
        echo "  status              Show pod and container status"
        echo "  logs [container] [N] Show logs for container (default: backend, 100 lines)"
        echo "  follow [container]  Follow container logs in real-time (default: backend)"
        echo "  restart             Restart the Opik pod"
        echo "  stop                Stop the Opik pod"
        echo "  start               Start the Opik pod"
        echo "  health              Check all health endpoints"
        echo "  ps                  List all Opik containers"
        echo "  shell               Open a shell as opik-user"
        echo "  exec {cmd}          Run arbitrary command as opik-user"
        echo "  reinstall           Reinstall all quadlets and restart"
        echo "  clean               Stop and remove all data (WARNING: destructive!)"
        echo ""
        echo "Database Access:"
        echo "  mysql-shell         Connect to MySQL shell"
        echo "  clickhouse-shell    Connect to ClickHouse shell"
        echo "  redis-cli           Connect to Redis CLI"
        echo "  minio-console       Show MinIO console access info"
        echo ""
        echo "Container Names:"
        echo "  frontend, backend, python-backend, mysql, redis,"
        echo "  clickhouse, zookeeper, minio, minio-init"
        echo ""
        echo "Examples:"
        echo "  $0 status                    Show all service status"
        echo "  $0 logs frontend 200         Show last 200 frontend log lines"
        echo "  $0 follow backend            Follow backend logs"
        echo "  $0 mysql-shell               Open MySQL console"
        echo "  $0 exec 'podman pod ps'      Run podman pod ps as opik-user"
        exit 1
        ;;
esac
