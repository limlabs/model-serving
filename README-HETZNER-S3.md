# Hetzner Object Storage for Dagster

Use Hetzner's S3-compatible Object Storage with Dagster for cloud asset storage and Modal compute integration.

**Cost**: ~€1.50/month for 100GB storage + 100GB traffic

## Quick Start (15 minutes)

### 1. Create Object Storage in Hetzner Console (5 minutes)

1. Go to https://console.hetzner.cloud/
2. Navigate to **Storage** → **Object Storage**
3. Click **Create Project**
4. Choose a region:
   - `fsn1` - Falkenstein, Germany
   - `nbg1` - Nuremberg, Germany
   - `hel1` - Helsinki, Finland
5. Note your credentials:
   - **Endpoint**: `https://fsn1.your-objectstorage.com` (or nbg1/hel1)
   - **Access Key ID**: Your access key
   - **Secret Access Key**: Your secret key

### 2. Run Setup Script (2 minutes)

```bash
cd scripts
./setup-datalake.sh
```

The script will:
- Test your S3 connection
- Create the bucket if it doesn't exist
- Configure environment variables
- Provide next steps

### 3. Install Dependencies (2 minutes)

```bash
# Quick method: Install in running containers
sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) \
  podman exec dagster-webserver pip install dagster-aws boto3

sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) \
  podman exec dagster-daemon pip install dagster-aws boto3
```

### 4. Update Dagster Configuration (1 minute)

No changes needed to `dagster.yaml` - S3 is configured per-asset using the I/O manager.

Your existing config with local logs is fine:
```yaml
compute_logs:
  module: dagster.core.storage.local_compute_log_manager
  class: LocalComputeLogManager
  config:
    base_dir: /opt/dagster/dagster_home/logs
```

### 5. Verify Quadlet Configuration (automatic)

The setup script automatically configures the quadlet files to use `EnvironmentFile` for S3 credentials:

```ini
EnvironmentFile=-/var/lib/dagster/.config/environment.d/dagster-s3.conf
```

This keeps secrets out of the quadlet files. The `-` prefix makes the file optional, so services start even if S3 isn't configured.

### 6. Restart Dagster (1 minute)

```bash
./dagster-manage.sh reload
./dagster-manage.sh restart
```

### 7. Test (1 minute)

1. Open http://localhost:3002
2. Materialize the `raw_data` asset from `example_s3_assets.py`
3. Check Hetzner Console → Object Storage to verify data

## Using S3 in Your Assets

### Basic S3 I/O Manager

```python
from dagster import asset, Definitions
from dagster_aws.s3 import S3PickleIOManager, S3Resource
import os

# Configure S3 resource
s3_resource = S3Resource(
    endpoint_url=os.getenv("DAGSTER_S3_ENDPOINT_URL"),
    region_name=os.getenv("DAGSTER_S3_REGION"),
)

# Configure I/O manager
s3_io_manager = S3PickleIOManager(
    s3_bucket=os.getenv("DAGSTER_S3_BUCKET"),
    s3_prefix="assets",
    s3_resource=s3_resource,
)

@asset(io_manager_key="s3_io_manager")
def my_data():
    """This asset will be stored in S3."""
    return {"values": [1, 2, 3, 4, 5]}

@asset(io_manager_key="s3_io_manager")
def processed_data(my_data):
    """This reads from S3 and writes back to S3."""
    return {"sum": sum(my_data["values"])}

defs = Definitions(
    assets=[my_data, processed_data],
    resources={
        "s3_io_manager": s3_io_manager,
        "s3": s3_resource,
    },
)
```

### Direct S3 Access

```python
from dagster import asset
import boto3
import os

@asset
def custom_s3_asset():
    """Write directly to S3 using boto3."""
    s3_client = boto3.client(
        's3',
        endpoint_url=os.getenv("DAGSTER_S3_ENDPOINT_URL"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        region_name=os.getenv("DAGSTER_S3_REGION"),
    )
    
    bucket = os.getenv("DAGSTER_S3_BUCKET")
    key = "custom/data.json"
    
    s3_client.put_object(
        Bucket=bucket,
        Key=key,
        Body=b'{"message": "Hello from Dagster"}',
        ContentType='application/json'
    )
    
    return f"s3://{bucket}/{key}"
```

## Modal Integration

### Setup Modal

```bash
pip install modal
modal token new
```

### Store S3 Credentials in Modal

```bash
modal secret create hetzner-s3 \
  DAGSTER_S3_ENDPOINT_URL=https://fsn1.your-objectstorage.com \
  DAGSTER_S3_BUCKET=dagster-assets \
  DAGSTER_S3_REGION=fsn1 \
  AWS_ACCESS_KEY_ID=your-access-key \
  AWS_SECRET_ACCESS_KEY=your-secret-key
```

### Create Modal Function

```python
# modal_functions.py
import modal
import boto3
import os

stub = modal.Stub("dagster-compute")

image = modal.Image.debian_slim().pip_install(
    "boto3>=1.28.0",
    "pandas>=2.0.0",
)

@stub.function(
    image=image,
    secrets=[modal.Secret.from_name("hetzner-s3")],
    cpu=4,
    memory=8192,
)
def process_dataset(input_key: str, output_key: str):
    """Process data from Hetzner S3 using Modal compute."""
    
    s3 = boto3.client(
        's3',
        endpoint_url=os.environ["DAGSTER_S3_ENDPOINT_URL"],
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=os.environ["DAGSTER_S3_REGION"],
    )
    
    bucket = os.environ["DAGSTER_S3_BUCKET"]
    
    # Read from S3
    response = s3.get_object(Bucket=bucket, Key=input_key)
    data = response['Body'].read()
    
    # Process (your heavy computation here)
    import pandas as pd
    df = pd.read_json(data)
    result = df.describe().to_json()
    
    # Write back to S3
    s3.put_object(
        Bucket=bucket,
        Key=output_key,
        Body=result.encode('utf-8'),
    )
    
    return {"status": "success", "output_key": output_key}
```

Deploy:
```bash
modal deploy modal_functions.py
```

### Call from Dagster

```python
from dagster import asset
import modal

@asset(io_manager_key="s3_io_manager")
def raw_data():
    return {"values": list(range(10000))}

@asset
def modal_processed(raw_data):
    """Trigger Modal compute."""
    fn = modal.Function.lookup("dagster-compute", "process_dataset")
    
    result = fn.remote(
        input_key="assets/raw_data/latest.json",
        output_key="assets/processed/latest.json"
    )
    
    return result
```

## Managing Buckets

### Using AWS CLI

Install AWS CLI:
```bash
pip install awscli
```

Configure:
```bash
aws configure --profile hetzner
# Enter your Hetzner credentials
```

Create bucket:
```bash
aws s3 mb s3://dagster-assets \
  --endpoint-url https://fsn1.your-objectstorage.com \
  --profile hetzner
```

List buckets:
```bash
aws s3 ls \
  --endpoint-url https://fsn1.your-objectstorage.com \
  --profile hetzner
```

List objects:
```bash
aws s3 ls s3://dagster-assets/ \
  --endpoint-url https://fsn1.your-objectstorage.com \
  --profile hetzner
```

### Using Python

```python
import boto3

s3 = boto3.client(
    's3',
    endpoint_url='https://fsn1.your-objectstorage.com',
    aws_access_key_id='your-access-key',
    aws_secret_access_key='your-secret-key',
    region_name='fsn1',
)

# List buckets
buckets = s3.list_buckets()
print([b['Name'] for b in buckets['Buckets']])

# List objects in bucket
objects = s3.list_objects_v2(Bucket='dagster-assets')
for obj in objects.get('Contents', []):
    print(f"{obj['Key']} - {obj['Size']} bytes")
```

## Monitoring

### Check Storage Usage

Via Hetzner Console:
1. Go to Storage → Object Storage
2. View usage statistics

Via AWS CLI:
```bash
aws s3 ls s3://dagster-assets/ --recursive --summarize \
  --endpoint-url https://fsn1.your-objectstorage.com \
  --profile hetzner
```

### Monitor Costs

1. Go to Hetzner Console → Billing
2. View Object Storage costs
3. Set up billing alerts if needed

## Troubleshooting

### Connection Errors

```bash
# Test connection
python3 << 'EOF'
import boto3
s3 = boto3.client(
    's3',
    endpoint_url='https://fsn1.your-objectstorage.com',
    aws_access_key_id='your-key',
    aws_secret_access_key='your-secret',
)
print(s3.list_buckets())
EOF
```

### Dagster Can't Access S3

```bash
# Check environment variables
./dagster-manage.sh logs webserver | grep S3

# Verify credentials in container
sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) \
  podman exec dagster-webserver env | grep S3
```

### Permission Errors

Check bucket policy in Hetzner Console:
1. Go to Storage → Object Storage
2. Select your bucket
3. Check access permissions

## Production Considerations

### Security

1. **Use HTTPS**: Always use `https://` endpoints
2. **Rotate Keys**: Regularly rotate access keys
3. **Least Privilege**: Create separate keys for different services
4. **Environment Variables**: Never hardcode credentials

### Performance

1. **Choose Nearest Region**: Use fsn1/nbg1 for EU, hel1 for Nordic
2. **Compression**: Compress large assets before storing
3. **Partitioning**: Use partitioned assets for large datasets
4. **Caching**: Cache frequently accessed data locally

### Cost Optimization

1. **Lifecycle Policies**: Delete old assets automatically
2. **Compression**: Reduce storage costs
3. **Monitor Usage**: Set up billing alerts
4. **Clean Up**: Regularly delete unused data

## Migration from Local Storage

### 1. Backup Current Data

```bash
sudo tar -czf dagster-local-backup.tar.gz \
  /var/lib/dagster/dagster_home/storage \
  /var/lib/dagster/dagster_home/logs
```

### 2. Upload to S3 (Optional)

```bash
aws s3 sync /var/lib/dagster/dagster_home/storage/ \
  s3://dagster-assets/migrated/ \
  --endpoint-url https://fsn1.your-objectstorage.com \
  --profile hetzner
```

### 3. Update Asset Definitions

Change I/O manager:
```python
# Before
@asset
def my_asset():
    return data

# After
@asset(io_manager_key="s3_io_manager")
def my_asset():
    return data
```

### 4. Test and Validate

1. Materialize assets in Dagster UI
2. Verify data in Hetzner Console
3. Check compute logs are in S3

## Rollback

To revert to local storage:

```bash
# 1. Restore original dagster.yaml
sudo cp /var/lib/dagster/dagster_home/dagster.yaml.backup-* \
  /var/lib/dagster/dagster_home/dagster.yaml

# 2. Remove S3 env vars from quadlet files
sudo nano /var/lib/dagster/.config/containers/systemd/dagster-webserver.container
sudo nano /var/lib/dagster/.config/containers/systemd/dagster-daemon.container

# 3. Restart
./dagster-manage.sh reload
./dagster-manage.sh restart
```

## Resources

- **Hetzner Object Storage**: https://docs.hetzner.com/storage/object-storage/
- **Supported Actions**: https://docs.hetzner.com/storage/object-storage/supported-actions
- **Dagster S3 Integration**: https://docs.dagster.io/integrations/aws/s3
- **Modal Documentation**: https://modal.com/docs
- **AWS CLI S3**: https://docs.aws.amazon.com/cli/latest/reference/s3/

## Cost Example

**100GB storage + 100GB traffic/month:**
- Storage: 100 GB × €0.005 = €0.50
- Traffic: 100 GB × €0.01 = €1.00
- **Total: €1.50/month**

Much cheaper than self-hosted MinIO (~€11/month) but with less control.

## Next Steps

1. ✅ Create Object Storage project in Hetzner Console
2. ✅ Run `./scripts/setup-datalake.sh`
3. ✅ Install dependencies
4. ✅ Update Dagster configuration
5. ✅ Restart Dagster
6. 🔲 Test with example assets
7. 🔲 Set up Modal integration
8. 🔲 Migrate existing assets
