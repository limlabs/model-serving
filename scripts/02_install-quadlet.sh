# 1. Create a dedicated user (no login shell, no home directory login)
sudo useradd -r -s /usr/sbin/nologin -m -d /var/lib/vllm vllm-user
sudo usermod -aG systemd-journal vllm-use

# Add subuid/subgid space for vllm-user to pull images
echo "vllm-user:100000:65536" | sudo tee -a /etc/subuid
echo "vllm-user:100000:65536" | sudo tee -a /etc/subgid

# 2. Enable systemd user services for this user
sudo loginctl enable-linger vllm-user

# 3. Set up the quadlet directory
sudo mkdir -p /var/lib/vllm/.config/containers/systemd/user
sudo cp ../quadlets/vllm-qwen.container /var/lib/vllm/.config/containers/systemd/
sudo cp ../quadlets/open-webui.container /var/lib/vllm/.config/containers/systemd/

# 4. Create the cache directory
sudo mkdir -p /var/lib/vllm/.cache/huggingface
sudo chown -R vllm-user:vllm-user /var/lib/vllm

# Restrict user from su/sudo
echo "vllm-user ALL=(ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers.d/vllm-user
sudo chmod 0440 /etc/sudoers.d/vllm-user

sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/$(id -u vllm-user) systemctl --user daemon-reload
sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/$(id -u vllm-user) systemctl --user start vllm-qwen.service
sudo -u vllm-user XDG_RUNTIME_DIR=/run/user/$(id -u vllm-user) systemctl --user start open-webui.service