#!/bin/sh
set -e

export PYTHONUSERBASE=/tmp/python
export PATH="/tmp/python/bin:$PATH"

echo "Installing Dagster..."
pip install --quiet --user dagster dagster-webserver

echo "Copying ycgraph to writable location..."
cp -r /opt/dagster/ycgraph /tmp/ycgraph
cd /tmp/ycgraph

echo "Installing ycgraph package..."
pip install --quiet --user -e .

echo "Starting Dagster gRPC server..."
exec dagster api grpc --host 0.0.0.0 --port 4000 --module-name yc_scraper.definitions
