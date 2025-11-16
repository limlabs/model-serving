FROM python:3.12-slim

# Set working directory
WORKDIR /opt/dagster

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
# Core Dagster dependencies
RUN pip install --no-cache-dir \
    dagster \
    dagster-webserver

# YCGraph specific dependencies
RUN pip install --no-cache-dir \
    playwright \
    beautifulsoup4 \
    lxml \
    pandas \
    pydantic \
    openai \
    requests

# Install Playwright browsers (if needed for scraping)
# Uncomment if you need browser automation
# RUN playwright install chromium && \
#     playwright install-deps chromium

# Set environment variables
ENV HOME=/root
ENV PYTHONUNBUFFERED=1

# Default command will be overridden by quadlet
CMD ["dagster", "api", "grpc", "--help"]
