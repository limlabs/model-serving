#!/bin/bash
set -e

# Setup script for Hetzner Object Storage with Dagster
# Uses Hetzner's S3-compatible Object Storage service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "Hetzner Object Storage Setup for Dagster"
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

# Update dagster-user's environment and quadlet files
echo ""
echo "Configuring dagster-user environment..."

DAGSTER_USER="dagster-user"
DAGSTER_HOME="/var/lib/dagster"

if id -u $DAGSTER_USER &>/dev/null; then
    # Create systemd environment file
    SYSTEMD_ENV_DIR="$DAGSTER_HOME/.config/environment.d"
    sudo mkdir -p "$SYSTEMD_ENV_DIR"
    
    sudo tee "$SYSTEMD_ENV_DIR/dagster-s3.conf" > /dev/null << EOF
DAGSTER_S3_ENDPOINT_URL=$S3_ENDPOINT
DAGSTER_S3_BUCKET=$S3_BUCKET
DAGSTER_S3_REGION=$S3_REGION
AWS_ACCESS_KEY_ID=$AWS_KEY
AWS_SECRET_ACCESS_KEY=$AWS_SECRET
EOF
    
    sudo chown -R $DAGSTER_USER:$DAGSTER_USER "$SYSTEMD_ENV_DIR"
    echo "✓ Systemd environment configured"
    
    # Update quadlet files to use EnvironmentFile (no secrets in quadlets)
    echo "Updating quadlet files..."
    QUADLET_DIR="$DAGSTER_HOME/.config/containers/systemd"
    
    for file in dagster-webserver.container dagster-daemon.container; do
        if [ -f "$QUADLET_DIR/$file" ]; then
            # Remove old S3 env vars if they exist (hardcoded secrets)
            sudo sed -i '/^Environment=DAGSTER_S3_/d' "$QUADLET_DIR/$file"
            sudo sed -i '/^Environment=AWS_ACCESS_KEY_ID/d' "$QUADLET_DIR/$file"
            sudo sed -i '/^Environment=AWS_SECRET_ACCESS_KEY/d' "$QUADLET_DIR/$file"
            
            # Add EnvironmentFile directive if not present
            if ! sudo grep -q "^EnvironmentFile=.*dagster-s3.conf" "$QUADLET_DIR/$file"; then
                sudo sed -i "/^Environment=DAGSTER_HOME=/a EnvironmentFile=-$SYSTEMD_ENV_DIR/dagster-s3.conf" "$QUADLET_DIR/$file"
            fi
            
            echo "✓ Updated $file"
        fi
    done
else
    echo "⚠ dagster-user not found, skipping user environment setup"
fi

# No dagster.yaml changes needed - S3 is configured per-asset
echo ""
echo "✓ Dagster configuration (no changes needed - S3 configured per-asset)"

# Install dependencies in containers
echo ""
echo "Installing Python dependencies in containers..."

if id -u $DAGSTER_USER &>/dev/null; then
    DAGSTER_UID=$(id -u $DAGSTER_USER)
    DAGSTER_RUNTIME_DIR="/run/user/$DAGSTER_UID"
    
    # Check if containers are running
    if sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR podman ps --format "{{.Names}}" | grep -q dagster-webserver; then
        echo "Installing in dagster-webserver..."
        sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR \
            podman exec dagster-webserver pip install --quiet dagster-aws boto3
        echo "✓ dagster-webserver"
        
        echo "Installing in dagster-daemon..."
        sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR \
            podman exec dagster-daemon pip install --quiet dagster-aws boto3
        echo "✓ dagster-daemon"
    else
        echo "⚠ Dagster containers not running - dependencies will be installed on next restart"
    fi
else
    echo "⚠ dagster-user not found"
fi
echo ""

# Copy example assets (only if they don't exist)
if [ ! -f "/var/lib/dagster/code/example_s3_assets.py" ]; then
    echo "Copying example S3 assets template..."
    if [ -f "$REPO_ROOT/config/dagster/example_s3_assets.py" ]; then
        sudo cp "$REPO_ROOT/config/dagster/example_s3_assets.py" /var/lib/dagster/code/ 2>/dev/null
        sudo chown $DAGSTER_USER:$DAGSTER_USER /var/lib/dagster/code/example_s3_assets.py 2>/dev/null
        echo "✓ Example template copied (you can modify or delete this)"
    fi
else
    echo "✓ Example assets already exist (skipping copy)"
fi

# Always ensure workspace.yaml includes the example (in case it was removed)
WORKSPACE_YAML="/var/lib/dagster/dagster_home/workspace.yaml"
if [ -f "$WORKSPACE_YAML" ]; then
    if ! sudo grep -q "example_s3_assets.py" "$WORKSPACE_YAML"; then
        echo "Adding example_s3_assets.py to workspace..."
        sudo tee -a "$WORKSPACE_YAML" > /dev/null << 'EOF'
  - python_file:
      relative_path: /opt/dagster/code/example_s3_assets.py
      working_directory: /opt/dagster/code
EOF
        echo "✓ Workspace updated"
    else
        echo "✓ Workspace already includes example_s3_assets.py"
    fi
fi

# Reload and restart Dagster
echo ""
echo "Reloading and restarting Dagster..."

if id -u $DAGSTER_USER &>/dev/null; then
    DAGSTER_UID=$(id -u $DAGSTER_USER)
    DAGSTER_RUNTIME_DIR="/run/user/$DAGSTER_UID"
    
    sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user daemon-reload
    echo "✓ Systemd reloaded"
    
    # Restart postgres first and wait for it to be ready
    echo "Restarting PostgreSQL..."
    sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user restart dagster-postgres
    
    # Wait for postgres to be ready (max 30 seconds)
    echo -n "Waiting for PostgreSQL to be ready"
    for i in {1..30}; do
        if sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR \
            podman exec dagster-postgres pg_isready -U dagster -d dagster &>/dev/null; then
            echo " ✓"
            break
        fi
        echo -n "."
        sleep 1
    done
    
    # Now restart webserver and daemon
    sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user restart dagster-webserver
    sudo -u $DAGSTER_USER XDG_RUNTIME_DIR=$DAGSTER_RUNTIME_DIR systemctl --user restart dagster-daemon
    echo "✓ Dagster restarted"
fi

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Endpoint: $S3_ENDPOINT"
echo "  Bucket:   $S3_BUCKET"
echo "  Region:   $S3_REGION"
echo ""
echo "✓ Credentials saved to $ENV_FILE"
echo "✓ Quadlet files updated"
echo "✓ Dependencies installed"
echo "✓ Dagster restarted"
echo ""
echo "Your assets will now be stored in S3 when you use:"
echo "  @asset(io_manager_key=\"s3_io_manager\")"
echo ""
echo "See example_s3_assets.py for a template, then write your own!"
echo ""
