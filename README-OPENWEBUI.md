# Open WebUI Setup

Open WebUI has been integrated into your vLLM model serving setup with automatic startup on boot.

## What is Open WebUI?

Open WebUI is a feature-rich, user-friendly web interface for interacting with LLM models. It provides a ChatGPT-like experience running entirely on your local machine.

## Setup

### First-time Installation

If you haven't already set up the vLLM service, run:

```bash
cd /Users/austin/model-serving/scripts
./02_install-quadlet.sh
```

This will:
1. Install the vLLM service quadlet
2. Install the Open WebUI quadlet
3. Start both services automatically

### If vLLM is Already Running

If you already have vLLM running and just want to add Open WebUI:

```bash
cd /Users/austin/model-serving/scripts
./vllm-manage.sh webui-reinstall
```

## Accessing Open WebUI

Once the service is running, open your browser and navigate to:

**http://localhost:3000**

On first access, you'll need to create an admin account.

## Configuration

The Open WebUI container is configured to:
- Run on port **3000** (mapped from container port 8080)
- Connect to vLLM API at **http://localhost:8000/v1**
- Persist data in a Docker volume named `open-webui`
- Restart automatically on system boot
- Start after vLLM service is ready

## Management Commands

### Check Status
```bash
./vllm-manage.sh status
```
Shows status of both vLLM and Open WebUI services.

### View Open WebUI Logs
```bash
# Last 100 lines (default)
./vllm-manage.sh webui-logs

# Last 200 lines
./vllm-manage.sh webui-logs 200
```

### Follow Open WebUI Logs in Real-time
```bash
./vllm-manage.sh webui-follow
```
Press Ctrl+C to exit.

### Restart Open WebUI
```bash
./vllm-manage.sh webui-restart
```

### Reinstall/Update Open WebUI
```bash
./vllm-manage.sh webui-reinstall
```

### Check Health Status
```bash
./vllm-manage.sh health
```
Checks both vLLM and Open WebUI endpoints.

## Troubleshooting

### Open WebUI won't start
1. Check if vLLM is running:
   ```bash
   ./vllm-manage.sh status
   ```

2. View Open WebUI logs:
   ```bash
   ./vllm-manage.sh webui-logs
   ```

3. Restart the service:
   ```bash
   ./vllm-manage.sh webui-restart
   ```

### Can't access http://localhost:3000
- Verify the container is running: `./vllm-manage.sh status`
- Check if port 3000 is available: `sudo lsof -i :3000`
- Review logs: `./vllm-manage.sh webui-logs`

### Open WebUI can't connect to vLLM
The Open WebUI container uses host networking to connect to vLLM. Verify:
1. vLLM is running and responding:
   ```bash
   curl http://localhost:8000/health
   ```
2. Check the Open WebUI environment variable:
   ```bash
   ./vllm-manage.sh exec "podman inspect open-webui | grep OPENAI_API_BASE_URL"
   ```

## Architecture

- **vLLM Service**: Runs on port 8000, provides the OpenAI-compatible API
- **Open WebUI**: Runs on port 3000, provides the web interface
- **Connection**: Open WebUI connects to vLLM via localhost:8000
- **Startup**: Open WebUI automatically starts after vLLM is ready
- **Data Persistence**: User data and settings stored in Docker volume

## References

- [vLLM Open WebUI Documentation](https://docs.vllm.ai/en/stable/deployment/frameworks/open-webui.html)
- [Open WebUI GitHub](https://github.com/open-webui/open-webui)
