FROM python:3.12-slim

# Set working directory
WORKDIR /opt/dagster

# Install system dependencies (including Playwright requirements)
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    ca-certificates \
    fonts-liberation \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libatspi2.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libwayland-client0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    xdg-utils \
    && rm -rf /var/lib/apt/lists/*

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Copy project files
COPY pyproject.toml uv.lock README.md ./
COPY yc_scraper ./yc_scraper

# Install dependencies using uv
RUN uv sync --frozen --no-dev

# Install Playwright browsers for scraping
# Note: install-deps is handled by manual apt-get above for better control
RUN uv run playwright install chromium chromium-headless-shell && \
    chmod -R 755 /root/.cache/ms-playwright && \
    find /root/.cache/ms-playwright -type f -exec chmod 644 {} \; && \
    find /root/.cache/ms-playwright -type d -exec chmod 755 {} \; && \
    find /root/.cache/ms-playwright -name "headless_shell" -exec chmod 755 {} \; && \
    find /root/.cache/ms-playwright -name "chrome" -exec chmod 755 {} \; && \
    find /root/.cache/ms-playwright -name "headless-shell" -exec chmod 755 {} \; && \
    echo "Playwright installation complete:" && \
    ls -laR /root/.cache/ms-playwright/

# Set environment variables
ENV HOME=/root
ENV PYTHONUNBUFFERED=1
ENV PATH="/opt/dagster/.venv/bin:$PATH"

# Copy Playwright browsers to a temporary location for entrypoint use
RUN cp -r /root/.cache/ms-playwright /tmp/playwright-browsers-backup

# Create entrypoint script to initialize Playwright cache from backup
RUN echo '#!/bin/bash' > /entrypoint.sh && \
    echo 'set -e' >> /entrypoint.sh && \
    echo '# Initialize Playwright cache if empty (volume mount scenario)' >> /entrypoint.sh && \
    echo 'CACHE_DIR="${HOME}/.cache/ms-playwright"' >> /entrypoint.sh && \
    echo 'if [ ! -f "${CACHE_DIR}/chromium_headless_shell-1194/INSTALLATION_COMPLETE" ]; then' >> /entrypoint.sh && \
    echo '  echo "Initializing Playwright browsers from image..."' >> /entrypoint.sh && \
    echo '  mkdir -p "${CACHE_DIR}"' >> /entrypoint.sh && \
    echo '  cp -r /tmp/playwright-browsers-backup/* "${CACHE_DIR}/" 2>/dev/null || cp -r /root/.cache/ms-playwright/* "${CACHE_DIR}/"' >> /entrypoint.sh && \
    echo '  chmod -R 755 "${CACHE_DIR}"' >> /entrypoint.sh && \
    echo '  find "${CACHE_DIR}" -type f \( -name "chrome" -o -name "headless_shell" \) -exec chmod 755 {} \;' >> /entrypoint.sh && \
    echo '  find "${CACHE_DIR}" -type f -name "*.so*" -exec chmod 755 {} \;' >> /entrypoint.sh && \
    echo '  echo "Playwright browsers initialized at ${CACHE_DIR}"' >> /entrypoint.sh && \
    echo 'fi' >> /entrypoint.sh && \
    echo 'exec "$@"' >> /entrypoint.sh && \
    chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

# Default command will be overridden by quadlet
CMD ["dagster", "api", "grpc", "--help"]
