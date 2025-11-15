#!/bin/bash
# vLLM Service Management Script

VLLM_USER="vllm-user"
VLLM_UID=$(id -u $VLLM_USER 2>/dev/null)
SERVICE_NAME="vllm-qwen.service"
QUADLET_FILE="vllm-qwen.container"
QUADLET_SOURCE="$(dirname "$0")/../quadlets/$QUADLET_FILE"
QUADLET_DEST="/var/lib/vllm/.config/containers/systemd/$QUADLET_FILE"

# Open WebUI configuration
WEBUI_SERVICE="open-webui.service"
WEBUI_QUADLET="open-webui.container"
WEBUI_QUADLET_SOURCE="$(dirname "$0")/../quadlets/$WEBUI_QUADLET"
WEBUI_QUADLET_DEST="/var/lib/vllm/.config/containers/systemd/$WEBUI_QUADLET"

# Helper function to run commands as vllm-user
run_as_vllm() {
    cd /tmp && sudo su -s /bin/sh $VLLM_USER -c "XDG_RUNTIME_DIR=/run/user/$VLLM_UID $*"
}

case "$1" in
    status)
        echo "=== vLLM Service Status ==="
        run_as_vllm "systemctl --user status $SERVICE_NAME"
        echo ""
        echo "=== Open WebUI Service Status ==="
        run_as_vllm "systemctl --user status $WEBUI_SERVICE"
        echo ""
        echo "=== Container Status ==="
        run_as_vllm "podman ps -a | grep -E 'vllm|open-webui'"
        ;;

    logs)
        LINES=${2:-100}
        echo "=== Service Logs (last $LINES lines) ==="
        journalctl --unit=user@$VLLM_UID.service -n $LINES --no-pager | grep -A2 -B2 vllm
        echo ""
        echo "=== Container Logs ==="
        run_as_vllm "podman logs vllm-qwen"
        ;;

    follow)
        echo "=== Following container logs (Ctrl+C to exit) ==="
        run_as_vllm "podman logs -f vllm-qwen"
        ;;

    restart)
        echo "Restarting vLLM service..."
        run_as_vllm "systemctl --user restart $SERVICE_NAME"
        echo "Done. Check status with: $0 status"
        ;;

    stop)
        echo "Stopping vLLM service..."
        run_as_vllm "systemctl --user stop $SERVICE_NAME"
        ;;

    start)
        echo "Starting vLLM service..."
        run_as_vllm "systemctl --user start $SERVICE_NAME"
        ;;

    reinstall)
        echo "Reinstalling quadlet..."
        sudo cp "$QUADLET_SOURCE" "$QUADLET_DEST"
        run_as_vllm "systemctl --user daemon-reload"
        run_as_vllm "systemctl --user restart $SERVICE_NAME"
        echo "Done. Check status with: $0 status"
        ;;

    reconfigure)
        if [ -z "$2" ]; then
            echo "Error: Model name required"
            echo "Usage: $0 reconfigure MODEL_NAME"
            echo "Example: $0 reconfigure Qwen/Qwen3-8B-FP8"
            exit 1
        fi

        NEW_MODEL="$2"
        echo "Reconfiguring vLLM service with model: $NEW_MODEL"

        # Update the quadlet file
        sudo sed -i.bak "s|Exec=--model .*|Exec=--model $NEW_MODEL|" "$QUADLET_DEST"

        # Update description
        MODEL_DESC=$(echo "$NEW_MODEL" | sed 's|.*/||')
        sudo sed -i "s|Description=vLLM OpenAI Server with .*|Description=vLLM OpenAI Server with $MODEL_DESC|" "$QUADLET_DEST"

        echo "Updated quadlet configuration:"
        sudo grep -E "Description=|Exec=" "$QUADLET_DEST"

        # Reload and restart
        run_as_vllm "systemctl --user daemon-reload"
        run_as_vllm "systemctl --user restart $SERVICE_NAME"

        echo ""
        echo "Done. Check status with: $0 status"
        echo "Note: Model download may take some time on first run"
        ;;

    health)
        echo "=== Checking vLLM health endpoint ==="
        curl -s http://localhost:8000/health | jq . || curl -v http://localhost:8000/health
        echo ""
        echo "=== Checking Open WebUI endpoint ==="
        curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://localhost:3000/ || echo "Open WebUI not responding"
        ;;

    shell)
        echo "Opening shell as $VLLM_USER..."
        echo "Run 'podman ps' or 'systemctl --user status $SERVICE_NAME'"
        cd /tmp && sudo su -s /bin/bash $VLLM_USER
        ;;

    exec)
        shift
        run_as_vllm "$*"
        ;;

    webui-logs)
        LINES=${2:-100}
        echo "=== Open WebUI Logs (last $LINES lines) ==="
        run_as_vllm "podman logs --tail $LINES open-webui"
        ;;

    webui-follow)
        echo "=== Following Open WebUI logs (Ctrl+C to exit) ==="
        run_as_vllm "podman logs -f open-webui"
        ;;

    webui-restart)
        echo "Restarting Open WebUI service..."
        run_as_vllm "systemctl --user restart $WEBUI_SERVICE"
        echo "Done. Check status with: $0 status"
        ;;

    webui-reinstall)
        echo "Reinstalling Open WebUI quadlet..."
        sudo cp "$WEBUI_QUADLET_SOURCE" "$WEBUI_QUADLET_DEST"
        run_as_vllm "systemctl --user daemon-reload"
        run_as_vllm "systemctl --user restart $WEBUI_SERVICE"
        echo "Done. Check status with: $0 status"
        ;;

    *)
        echo "vLLM Service Management Script"
        echo ""
        echo "Usage: $0 {command} [args]"
        echo ""
        echo "Commands:"
        echo "  status              Show service and container status"
        echo "  logs [N]            Show last N lines of vLLM logs (default: 100)"
        echo "  follow              Follow vLLM container logs in real-time"
        echo "  restart             Restart the vLLM service"
        echo "  stop                Stop the vLLM service"
        echo "  start               Start the vLLM service"
        echo "  reinstall           Reinstall vLLM quadlet and restart service"
        echo "  reconfigure MODEL   Reconfigure with a new model and restart"
        echo "  health              Check health endpoints"
        echo "  shell               Open a shell as vllm-user"
        echo "  exec {cmd}          Run arbitrary command as vllm-user"
        echo ""
        echo "Open WebUI Commands:"
        echo "  webui-logs [N]      Show last N lines of Open WebUI logs (default: 100)"
        echo "  webui-follow        Follow Open WebUI logs in real-time"
        echo "  webui-restart       Restart Open WebUI service"
        echo "  webui-reinstall     Reinstall Open WebUI quadlet and restart"
        echo ""
        echo "Examples:"
        echo "  $0 logs 200                      Show last 200 log lines"
        echo "  $0 follow                        Follow logs in real-time"
        echo "  $0 reconfigure Qwen/Qwen3-8B-FP8 Switch to a different model"
        echo "  $0 exec 'podman ps'              Run podman ps as vllm-user"
        exit 1
        ;;
esac
