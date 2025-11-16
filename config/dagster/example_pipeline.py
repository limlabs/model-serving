"""
Example Dagster pipeline for demonstration purposes.
This file should be placed in /var/lib/dagster/code/
"""

from dagster import asset, Definitions, ScheduleDefinition, define_asset_job
import pandas as pd
from datetime import datetime


@asset
def hello_world_asset():
    """A simple asset that returns a greeting."""
    return f"Hello from Dagster! Current time: {datetime.now()}"


@asset
def data_processing_asset(hello_world_asset: str):
    """An asset that depends on hello_world_asset."""
    df = pd.DataFrame({
        'message': [hello_world_asset],
        'timestamp': [datetime.now()],
        'status': ['success']
    })
    return df


@asset
def summary_asset(data_processing_asset: pd.DataFrame):
    """Generate a summary of the processed data."""
    return {
        'row_count': len(data_processing_asset),
        'columns': list(data_processing_asset.columns),
        'summary': 'Pipeline completed successfully'
    }


# Define a job that materializes all assets
all_assets_job = define_asset_job(
    name="all_assets_job",
    selection="*"
)

# Define a schedule to run the job daily at midnight
daily_schedule = ScheduleDefinition(
    job=all_assets_job,
    cron_schedule="0 0 * * *",  # Daily at midnight
)

# Create the Definitions object
defs = Definitions(
    assets=[hello_world_asset, data_processing_asset, summary_asset],
    jobs=[all_assets_job],
    schedules=[daily_schedule],
)
