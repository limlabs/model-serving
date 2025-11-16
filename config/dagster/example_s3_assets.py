"""
Example Dagster assets using S3-compatible object storage.
Assets are stored in Hetzner Object Storage, compute logs stay local.
"""

import os
from dagster import asset, AssetExecutionContext, Definitions
from dagster_aws.s3 import S3PickleIOManager, S3Resource
import boto3


# Configure S3 resource for Hetzner Object Storage
s3_resource = S3Resource(
    endpoint_url=os.getenv("DAGSTER_S3_ENDPOINT_URL"),
    region_name=os.getenv("DAGSTER_S3_REGION", "fsn1"),
)

# S3 I/O Manager - this stores your asset data in S3
s3_io_manager = S3PickleIOManager(
    s3_bucket=os.getenv("DAGSTER_S3_BUCKET", "dagster-assets"),
    s3_prefix="assets",
    s3_resource=s3_resource,
)


# Example: Simple data processing asset
@asset(
    description="Generate sample data and store in S3",
    io_manager_key="s3_io_manager",
)
def raw_data(context: AssetExecutionContext) -> dict:
    """Generate raw data to be stored in S3."""
    context.log.info("Generating raw data...")
    
    data = {
        "values": list(range(100)),
        "metadata": {"source": "example", "version": "1.0"}
    }
    
    context.log.info(f"Generated {len(data['values'])} data points")
    return data


@asset(
    description="Process raw data",
    io_manager_key="s3_io_manager",
)
def processed_data(context: AssetExecutionContext, raw_data: dict) -> dict:
    """Process raw data from S3."""
    context.log.info("Processing data...")
    
    processed = {
        "sum": sum(raw_data["values"]),
        "count": len(raw_data["values"]),
        "mean": sum(raw_data["values"]) / len(raw_data["values"]),
        "metadata": raw_data["metadata"]
    }
    
    context.log.info(f"Processed {processed['count']} values, mean={processed['mean']}")
    return processed


# Example: Modal integration for compute-intensive tasks
@asset(
    description="Run compute-intensive task on Modal",
    io_manager_key="s3_io_manager",
)
def modal_computed_asset(context: AssetExecutionContext, processed_data: dict) -> dict:
    """
    Example of using Modal for compute.
    
    In production, you would:
    1. Deploy a Modal function that reads from S3
    2. Trigger the Modal function from this asset
    3. Have Modal write results back to S3
    4. Return a reference or the actual data
    """
    context.log.info("Triggering Modal compute...")
    
    # Placeholder for Modal integration
    # In real implementation:
    # import modal
    # stub = modal.Stub("dagster-compute")
    # result = stub.run_function(processed_data)
    
    result = {
        "input_mean": processed_data["mean"],
        "computed_value": processed_data["mean"] * 2,
        "compute_backend": "modal",
        "status": "success"
    }
    
    context.log.info(f"Modal compute completed: {result}")
    return result


# Example: Asset that writes directly to S3 using boto3
@asset(
    description="Write custom data directly to S3",
)
def custom_s3_asset(context: AssetExecutionContext) -> str:
    """Example of writing directly to S3 using boto3."""
    
    s3_client = boto3.client(
        's3',
        endpoint_url=os.getenv("DAGSTER_S3_ENDPOINT_URL"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        region_name=os.getenv("DAGSTER_S3_REGION", "fsn1"),
        use_ssl=os.getenv("DAGSTER_S3_USE_SSL", "true").lower() == "true",
    )
    
    bucket = os.getenv("DAGSTER_S3_BUCKET", "dagster-assets")
    key = "custom/example-file.txt"
    content = "This is custom content written directly to S3"
    
    context.log.info(f"Writing to s3://{bucket}/{key}")
    
    s3_client.put_object(
        Bucket=bucket,
        Key=key,
        Body=content.encode('utf-8'),
        ContentType='text/plain'
    )
    
    s3_url = f"s3://{bucket}/{key}"
    context.log.info(f"Successfully wrote to {s3_url}")
    
    return s3_url


# Define the Dagster definitions with S3 I/O manager
defs = Definitions(
    assets=[
        raw_data,
        processed_data,
        modal_computed_asset,
        custom_s3_asset,
    ],
    resources={
        "s3_io_manager": s3_io_manager,
        "s3": s3_resource,
    },
)
