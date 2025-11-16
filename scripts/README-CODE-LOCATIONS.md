# Dagster Code Locations Management

The `setup-dagster-code-locations.sh` script provides independent management of Dagster code locations.

## Usage

```bash
./setup-dagster-code-locations.sh {ycgraph|example-s3|all|list|remove <name>}
```

## Commands

### Setup/Update Code Locations

- **`ycgraph`** - Setup or update the ycgraph code location (idempotent)
  - Automatically clones ycgraph to your home directory if not present
  - Builds custom Docker image with pre-installed dependencies (playwright, beautifulsoup4, lxml, pandas, pydantic, openai, requests)
  - Mounts your home directory's ycgraph repo into the container
  - This allows you to manage the repo with your own git credentials
  - Adds to workspace.yaml if not already present
  - Restarts Dagster services

- **`example-s3`** - Setup example S3 assets
  - Copies example_s3_assets.py template
  - Adds to workspace.yaml if not already present
  - Restarts Dagster services

- **`all`** - Setup all code locations
  - Runs both ycgraph and example-s3 setup

### List and Remove

- **`list`** - Display current code locations
  - Shows workspace.yaml configuration
  - Lists contents of code directory

- **`remove <name>`** - Remove a code location
  - Creates backup of workspace.yaml
  - Provides instructions for manual removal

## Examples

```bash
# Setup ycgraph (automatically clones if needed, creates symlink, installs deps)
./setup-dagster-code-locations.sh ycgraph

# Setup example S3 assets
./setup-dagster-code-locations.sh example-s3

# Setup all code locations
./setup-dagster-code-locations.sh all

# List current code locations
./setup-dagster-code-locations.sh list

# Run again anytime - it's idempotent!
./setup-dagster-code-locations.sh ycgraph
```

## Workflow for ycgraph Development

Since ycgraph is mounted from your home directory, you can work on it normally:

```bash
# Work on ycgraph in your home directory
cd ~/ycgraph
git pull
# ... make changes ...
git add .
git commit -m "Update"
git push

# Restart the code server to pick up changes
sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) systemctl --user restart ycgraph-code-server

# If you need to update dependencies, rebuild the image and restart
cd /path/to/model-serving/scripts
./build-ycgraph-image.sh
sudo -u dagster-user XDG_RUNTIME_DIR=/run/user/$(id -u dagster-user) systemctl --user restart ycgraph-code-server
```

## Adding Custom Code Locations

To add your own code location:

1. Add your code to `/var/lib/dagster/code/`
2. Modify the script to add a new function (e.g., `setup_mycode()`)
3. Add the function to the command dispatcher
4. Or manually edit `/var/lib/dagster/dagster_home/workspace.yaml`

### Example workspace.yaml entry for Python file:

```yaml
load_from:
  - python_file:
      relative_path: /opt/dagster/code/my_pipeline.py
      working_directory: /opt/dagster/code
```

### Example workspace.yaml entry for Python package:

```yaml
load_from:
  - python_package:
      package_name: my_package
      working_directory: /opt/dagster/code/my_package
```

## Notes

- The script requires `dagster-user` to exist (created by main setup script)
- Services are automatically restarted after changes
- Dependencies are installed in both webserver and daemon containers
- If containers aren't running, dependencies will need manual installation
