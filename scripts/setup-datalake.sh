#!/bin/bash
set -e

# Setup script for Data Lake infrastructure
# Includes Hetzner S3 Object Storage and Nessie Iceberg Catalog

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "Data Lake Setup (S3 + Nessie Catalog)"
echo "=========================================="
echo ""
echo "Prerequisites:"
echo "1. Create Object Storage project at https://console.hetzner.cloud/"
echo "2. Go to Storage → Object Storage → Create Project"
echo "3. Note your S3 endpoint, access key, and secret key"
echo ""
echo "Hetzner Object Storage endpoints by region:"
echo "  - Falkenstein: fsn1.your-objectstorage.com"
echo "  - Nuremberg: nbg1.your-objectstorage.com"
echo "  - Helsinki: hel1.your-objectstorage.com"
echo ""
read -p "Press Enter to continue..."
echo ""

# Collect configuration
# Check if config already exists
ENV_FILE="$REPO_ROOT/config/dagster/dagster.env"
if [ -f "$ENV_FILE" ]; then
    echo "Found existing configuration in $ENV_FILE"
    read -p "Use existing config? (y/n) [y]: " USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-y}
    
    if [ "$USE_EXISTING" = "y" ]; then
        # Load existing config
        source "$ENV_FILE"
        S3_ENDPOINT=$DAGSTER_S3_ENDPOINT_URL
        S3_BUCKET=$DAGSTER_S3_BUCKET
        S3_REGION=$DAGSTER_S3_REGION
        AWS_KEY=$AWS_ACCESS_KEY_ID
        AWS_SECRET=$AWS_SECRET_ACCESS_KEY
        
        echo "✓ Using existing configuration"
        echo "  Endpoint: $S3_ENDPOINT"
        echo "  Bucket: $S3_BUCKET"
        echo ""
    else
        # Prompt for new config
        echo "Enter your Hetzner Object Storage details:"
        echo ""
        read -p "S3 Endpoint (e.g., https://fsn1.your-objectstorage.com): " S3_ENDPOINT
        read -p "Bucket Name [dagster-assets]: " S3_BUCKET
        S3_BUCKET=${S3_BUCKET:-dagster-assets}
        read -p "Region (fsn1, nbg1, or hel1) [fsn1]: " S3_REGION
        S3_REGION=${S3_REGION:-fsn1}
        read -p "Access Key ID: " AWS_KEY
        read -sp "Secret Access Key: " AWS_SECRET
        echo ""
        echo ""
    fi
else
    # No existing config, prompt for new
    echo "Enter your Hetzner Object Storage details:"
    echo ""
    read -p "S3 Endpoint (e.g., https://fsn1.your-objectstorage.com): " S3_ENDPOINT
    read -p "Bucket Name [dagster-assets]: " S3_BUCKET
    S3_BUCKET=${S3_BUCKET:-dagster-assets}
    read -p "Region (fsn1, nbg1, or hel1) [fsn1]: " S3_REGION
    S3_REGION=${S3_REGION:-fsn1}
    read -p "Access Key ID: " AWS_KEY
    read -sp "Secret Access Key: " AWS_SECRET
    echo ""
    echo ""
fi

# Validate inputs
if [ -z "$S3_ENDPOINT" ] || [ -z "$AWS_KEY" ] || [ -z "$AWS_SECRET" ]; then
    echo "Error: All fields are required"
    exit 1
fi

# Install boto3 if not present
echo "Checking for boto3..."
if ! python3 -c "import boto3" 2>/dev/null; then
    echo "Installing boto3..."
    sudo apt-get update -qq
    sudo apt-get install -y python3-boto3
fi

# Test connection and create bucket if needed
echo ""
echo "Testing S3 connection..."
python3 << PYEOF
import sys
import boto3
from botocore.exceptions import ClientError

try:
    s3_client = boto3.client(
        's3',
        endpoint_url='$S3_ENDPOINT',
        aws_access_key_id='$AWS_KEY',
        aws_secret_access_key='$AWS_SECRET',
        region_name='$S3_REGION',
    )
    
    # Test connection
    print("✓ Connection successful!")
    
    # List existing buckets
    response = s3_client.list_buckets()
    existing_buckets = [b['Name'] for b in response['Buckets']]
    print(f"✓ Found {len(existing_buckets)} existing bucket(s)")
    
    # Check if our bucket exists
    if '$S3_BUCKET' in existing_buckets:
        print(f"✓ Bucket '$S3_BUCKET' already exists")
    else:
        print(f"Creating bucket '$S3_BUCKET'...")
        try:
            # Hetzner doesn't require LocationConstraint
            s3_client.create_bucket(Bucket='$S3_BUCKET')
            print(f"✓ Bucket '$S3_BUCKET' created successfully")
        except ClientError as e:
            if e.response['Error']['Code'] == 'BucketAlreadyOwnedByYou':
                print(f"✓ Bucket '$S3_BUCKET' already exists")
            else:
                print(f"✗ Failed to create bucket: {e}")
                sys.exit(1)
    
    # Test write access
    print("Testing write access...")
    test_key = '.dagster-test'
    s3_client.put_object(
        Bucket='$S3_BUCKET',
        Key=test_key,
        Body=b'test',
    )
    print("✓ Write access confirmed")
    
    # Clean up test object
    s3_client.delete_object(Bucket='$S3_BUCKET', Key=test_key)
    
except ImportError:
    print("✗ boto3 not installed. Install with: pip3 install boto3")
    sys.exit(1)
except Exception as e:
    print(f"✗ S3 connection failed: {e}")
    print("")
    print("Troubleshooting:")
    print("1. Verify endpoint URL is correct (should start with https://)")
    print("2. Check access key and secret key")
    print("3. Ensure Object Storage project is active in Hetzner console")
    sys.exit(1)
PYEOF

if [ $? -ne 0 ]; then
    echo ""
    echo "Setup failed. Please check your credentials and try again."
    exit 1
fi

echo ""
echo "Creating environment configuration..."

# Create environment file
ENV_FILE="$REPO_ROOT/config/dagster/dagster.env"
cat > "$ENV_FILE" << EOF
# Hetzner Object Storage Configuration for Dagster
# Generated on $(date)

DAGSTER_S3_ENDPOINT_URL=$S3_ENDPOINT
DAGSTER_S3_BUCKET=$S3_BUCKET
DAGSTER_S3_REGION=$S3_REGION
AWS_ACCESS_KEY_ID=$AWS_KEY
AWS_SECRET_ACCESS_KEY=$AWS_SECRET
EOF

echo "✓ Environment file created: $ENV_FILE"

echo ""
echo "=========================================="
echo "S3 Storage Setup Complete!"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Endpoint: $S3_ENDPOINT"
echo "  Bucket:   $S3_BUCKET"
echo "  Region:   $S3_REGION"
echo ""
echo "✓ Credentials saved to $ENV_FILE"
echo ""
echo "Note: To integrate with Dagster, you'll need to:"
echo "  1. Configure Dagster environment with these credentials"
echo "  2. Install dagster-aws and boto3 in Dagster containers"
echo "  3. Use @asset(io_manager_key=\"s3_io_manager\") in your code"
echo ""

# Setup Nessie Catalog
echo "=========================================="
echo "Setting up Nessie Iceberg Catalog"
echo "=========================================="
echo ""

NESSIE_USER="nessie-user"
NESSIE_HOME="/var/lib/nessie"
NESSIE_SUBID_START="593216"  # Different range from dagster-user

# Create nessie user if it doesn't exist
if ! id -u $NESSIE_USER &>/dev/null; then
    echo "Creating $NESSIE_USER system user..."
    sudo useradd -r -s /usr/sbin/nologin -m -d $NESSIE_HOME $NESSIE_USER
    echo "✓ User created"
else
    echo "✓ User $NESSIE_USER already exists"
fi

# Add subuid/subgid space for rootless podman (remove duplicates first)
sudo sed -i "/^$NESSIE_USER:/d" /etc/subuid
sudo sed -i "/^$NESSIE_USER:/d" /etc/subgid
echo "$NESSIE_USER:$NESSIE_SUBID_START:65536" | sudo tee -a /etc/subuid > /dev/null
echo "$NESSIE_USER:$NESSIE_SUBID_START:65536" | sudo tee -a /etc/subgid > /dev/null
echo "✓ Configured subuid/subgid for $NESSIE_USER: $NESSIE_SUBID_START:65536"

# Enable systemd user services
sudo loginctl enable-linger $NESSIE_USER
echo "✓ Enabled linger for $NESSIE_USER"

# Migrate podman to use new subuid/subgid ranges
echo "Migrating podman configuration..."
NESSIE_UID=$(id -u $NESSIE_USER)
NESSIE_RUNTIME_DIR="/run/user/$NESSIE_UID"
if [ ! -d "$NESSIE_RUNTIME_DIR" ]; then
    sudo mkdir -p "$NESSIE_RUNTIME_DIR"
    sudo chown $NESSIE_USER:$NESSIE_USER "$NESSIE_RUNTIME_DIR"
    sudo chmod 700 "$NESSIE_RUNTIME_DIR"
fi
# Run from /tmp to avoid permission issues
(cd /tmp && sudo -u $NESSIE_USER XDG_RUNTIME_DIR=$NESSIE_RUNTIME_DIR podman system migrate)
echo "✓ Podman migrated"

# Create necessary directories
echo "Creating Nessie directories..."
sudo mkdir -p $NESSIE_HOME/postgres
sudo mkdir -p $NESSIE_HOME/.config/containers/systemd
sudo mkdir -p $NESSIE_HOME/.local/share/containers/storage
sudo mkdir -p $NESSIE_HOME/.cache/containers
sudo chown -R $NESSIE_USER:$NESSIE_USER $NESSIE_HOME
echo "✓ Directories created"

# Copy quadlet files
echo "Installing Nessie quadlet files..."
QUADLET_DIR="$NESSIE_HOME/.config/containers/systemd"

for file in nessie-network.network nessie-postgres.container nessie.container; do
    if [ -f "$REPO_ROOT/quadlets/$file" ]; then
        sudo cp "$REPO_ROOT/quadlets/$file" "$QUADLET_DIR/"
        sudo chown $NESSIE_USER:$NESSIE_USER "$QUADLET_DIR/$file"
        echo "✓ Installed $file"
    else
        echo "⚠ Warning: $file not found in $REPO_ROOT/quadlets/"
    fi
done

# Reload systemd and start services
echo ""
echo "Starting Nessie services..."
sudo -u $NESSIE_USER XDG_RUNTIME_DIR=$NESSIE_RUNTIME_DIR systemctl --user daemon-reload
echo "✓ Systemd reloaded"

# Start network first
sudo -u $NESSIE_USER XDG_RUNTIME_DIR=$NESSIE_RUNTIME_DIR systemctl --user start nessie-network-network.service
echo "✓ Network started"

# Start postgres
echo "Starting PostgreSQL..."
sudo -u $NESSIE_USER XDG_RUNTIME_DIR=$NESSIE_RUNTIME_DIR systemctl --user start nessie-postgres.service

# Wait for postgres to be ready
echo -n "Waiting for PostgreSQL to be ready"
for i in {1..30}; do
    if sudo -u $NESSIE_USER XDG_RUNTIME_DIR=$NESSIE_RUNTIME_DIR \
        podman exec nessie-postgres pg_isready -U nessie -d nessie &>/dev/null 2>&1; then
        echo " ✓"
        echo "✓ PostgreSQL started"
        break
    fi
    echo -n "."
    sleep 1
done

# Start Nessie
sudo -u $NESSIE_USER XDG_RUNTIME_DIR=$NESSIE_RUNTIME_DIR systemctl --user start nessie.service
echo "✓ Nessie started"

# Wait for Nessie to be ready
echo -n "Waiting for Nessie API to be ready"
for i in {1..30}; do
    if curl -sf http://localhost:19120/api/v2/config > /dev/null 2>&1; then
        echo " ✓"
        break
    fi
    echo -n "."
    sleep 1
done

# Update nginx configuration
echo ""
echo "Configuring nginx for Nessie..."
if [ -d "/var/lib/nginx-proxy/conf.d" ]; then
    sudo cp "$REPO_ROOT/config/nginx/conf.d/nessie.conf" /var/lib/nginx-proxy/conf.d/
    sudo chown nginx-user:nginx-user /var/lib/nginx-proxy/conf.d/nessie.conf
    sudo chmod 644 /var/lib/nginx-proxy/conf.d/nessie.conf
    echo "✓ Nginx configuration copied"
else
    echo "⚠ Nginx directory not found, skipping nginx config"
fi

# Update dnsmasq configuration
echo "Configuring DNS for Nessie..."
if [ -d "/var/lib/dnsmasq-llm" ]; then
    sudo cp "$REPO_ROOT/config/dnsmasq/dnsmasq.conf" /var/lib/dnsmasq-llm/
    sudo chown dnsmasq-user:dnsmasq-user /var/lib/dnsmasq-llm/dnsmasq.conf
    sudo chmod 644 /var/lib/dnsmasq-llm/dnsmasq.conf
    echo "✓ DNS configuration copied"
else
    echo "⚠ DNSmasq directory not found, skipping DNS config"
fi

# Reload nginx and dnsmasq if they exist
"$SCRIPT_DIR/reload-nginx-dnsmasq.sh" 2>/dev/null || echo "⚠ Could not reload nginx/dnsmasq (may need manual restart)"

echo ""
echo "=========================================="
echo "Nessie Setup Complete!"
echo "=========================================="
echo ""
echo "Nessie Catalog is now running:"
echo "  Internal: http://localhost:19120"
echo "  External: https://nessie.liminati.internal"
echo "  API:      https://nessie.liminati.internal/api/v2/"
echo ""
echo "Services status:"
sudo -u $NESSIE_USER XDG_RUNTIME_DIR=$NESSIE_RUNTIME_DIR systemctl --user status nessie-postgres.service --no-pager -l || true
sudo -u $NESSIE_USER XDG_RUNTIME_DIR=$NESSIE_RUNTIME_DIR systemctl --user status nessie.service --no-pager -l || true
echo ""
echo "Data Lake setup complete!"
echo "  - S3 Storage: $S3_ENDPOINT/$S3_BUCKET"
echo "  - Nessie Catalog: https://nessie.liminati.internal"
echo ""
