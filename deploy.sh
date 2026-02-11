#!/bin/bash
# =============================================================================
# Deploy SQL Server, Database Watcher, and Azure Data Explorer
# =============================================================================
set -euo pipefail

# ---------- Configuration ----------
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-database-watcher}"
LOCATION="uksouth"
SQL_SERVER_NAME="${SQL_SERVER_NAME:-sql-dbwatcher-$(openssl rand -hex 4)}"
SQL_ADMIN_LOGIN="${SQL_ADMIN_LOGIN:-sqladmin}"
ADX_CLUSTER_NAME="${ADX_CLUSTER_NAME:-adxdbwatcher$(openssl rand -hex 4)}"
WATCHER_NAME="${WATCHER_NAME:-watcher-sqldb-uksouth}"

echo "============================================="
echo " Database Watcher Deployment"
echo "============================================="
echo "Resource Group : $RESOURCE_GROUP"
echo "Location       : $LOCATION"
echo "SQL Server     : $SQL_SERVER_NAME"
echo "ADX Cluster    : $ADX_CLUSTER_NAME"
echo "Watcher        : $WATCHER_NAME"
echo "============================================="

# ---------- Prompt for SQL password ----------
if [ -z "${SQL_ADMIN_PASSWORD:-}" ]; then
  read -rsp "Enter SQL Server admin password: " SQL_ADMIN_PASSWORD
  echo
fi

# ---------- Create resource group ----------
echo "[1/4] Creating resource group..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

# ---------- Deploy Bicep template ----------
echo "[2/4] Deploying infrastructure (this will take ~15-20 minutes for ADX cluster)..."
DEPLOYMENT_OUTPUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file main.bicep \
  --parameters \
    sqlServerName="$SQL_SERVER_NAME" \
    sqlAdminLogin="$SQL_ADMIN_LOGIN" \
    sqlAdminPassword="$SQL_ADMIN_PASSWORD" \
    adxClusterName="$ADX_CLUSTER_NAME" \
    watcherName="$WATCHER_NAME" \
  --output json)

echo "[3/4] Extracting outputs..."
SQL_FQDN=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.sqlServerFqdn.value')
ADX_URI=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.adxClusterUri.value')
WATCHER_PRINCIPAL_ID=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.watcherPrincipalId.value')

# ---------- Grant watcher identity access to SQL ----------
echo "[4/4] Post-deployment steps..."
echo ""
echo "=================================================="
echo "  IMPORTANT - Manual step required"
echo "=================================================="
echo ""
echo "You must grant the Database Watcher system-assigned"
echo "managed identity read access to your SQL database."
echo "Connect to your SQL database and run the following T-SQL:"
echo ""
echo "  CREATE USER [${WATCHER_NAME}] FROM EXTERNAL PROVIDER;"
echo "  ALTER ROLE [db_datareader] ADD MEMBER [${WATCHER_NAME}];"
echo "  GRANT VIEW DATABASE PERFORMANCE STATE TO [${WATCHER_NAME}];"
echo "  GRANT VIEW SERVER PERFORMANCE STATE TO [${WATCHER_NAME}];"
echo ""

# ---------- Start the watcher ----------
echo "Starting Database Watcher..."
az rest \
  --method post \
  --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DatabaseWatcher/watchers/${WATCHER_NAME}/start?api-version=2024-10-01-preview" \
  --output none 2>/dev/null || echo "Note: Start the watcher manually after granting SQL permissions."

echo ""
echo "============================================="
echo "  Deployment Complete"
echo "============================================="
echo "SQL Server FQDN   : $SQL_FQDN"
echo "ADX Cluster URI    : $ADX_URI"
echo "ADX Database       : sqlmonitoring"
echo "Watcher            : $WATCHER_NAME"
echo "Watcher Principal  : $WATCHER_PRINCIPAL_ID"
echo ""
echo "Next steps:"
echo "  1. Run the T-SQL above on your SQL database"
echo "  2. Start the watcher from Azure Portal if not started"
echo "  3. Query telemetry in ADX: ${ADX_URI}"
echo "============================================="
