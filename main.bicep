// ============================================================================
// Deploy SQL Server, Database Watcher, and Azure Data Explorer in UK South
// ============================================================================

@description('Location for all resources')
param location string = 'uksouth'

@description('SQL Server name')
param sqlServerName string

@description('SQL Server administrator login')
param sqlAdminLogin string

@description('SQL Server administrator password')
@secure()
param sqlAdminPassword string

@description('SQL Database name')
param sqlDatabaseName string = 'sampledb'

@description('SQL Database SKU name')
@allowed([
  'Basic'
  'S0'
  'S1'
  'S2'
  'GP_S_Gen5_1'
  'GP_S_Gen5_2'
])
param sqlDatabaseSku string = 'S0'

@description('Azure Data Explorer cluster name')
param adxClusterName string

@description('Azure Data Explorer database name')
param adxDatabaseName string = 'sqlmonitoring'

@description('ADX cluster SKU name')
@allowed([
  'Dev(No SLA)_Standard_D11_v2'
  'Standard_E2ads_v5'
  'Standard_E4ads_v5'
])
param adxSkuName string = 'Dev(No SLA)_Standard_D11_v2'

@description('ADX cluster SKU tier')
@allowed([
  'Basic'
  'Standard'
])
param adxSkuTier string = 'Basic'

@description('Database Watcher name')
param watcherName string

@description('Tags for all resources')
param tags object = {
  environment: 'dev'
  project: 'database-watcher'
}

// ============================================================================
// User-Assigned Managed Identity for Database Watcher
// ============================================================================
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${watcherName}'
  location: location
  tags: tags
}

// ============================================================================
// SQL Server
// ============================================================================
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  tags: tags
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

// Allow Azure services to access SQL Server
resource sqlFirewallAllowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ============================================================================
// SQL Database
// ============================================================================
resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  tags: tags
  sku: {
    name: sqlDatabaseSku
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648 // 2 GB
    zoneRedundant: false
  }
}

// ============================================================================
// Azure Data Explorer (Kusto) Cluster
// ============================================================================
resource adxCluster 'Microsoft.Kusto/clusters@2023-08-15' = {
  name: adxClusterName
  location: location
  tags: tags
  sku: {
    name: adxSkuName
    tier: adxSkuTier
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    enableStreamingIngest: true
    enableAutoStop: true
  }
}

// ============================================================================
// Azure Data Explorer Database
// ============================================================================
resource adxDatabase 'Microsoft.Kusto/clusters/databases@2023-08-15' = {
  parent: adxCluster
  name: adxDatabaseName
  location: location
  kind: 'ReadWrite'
  properties: {
    softDeletePeriod: 'P365D'
    hotCachePeriod: 'P31D'
  }
}

// ============================================================================
// Grant Managed Identity admin rights on ADX database
// ============================================================================
resource adxDatabasePrincipal 'Microsoft.Kusto/clusters/databases/principalAssignments@2023-08-15' = {
  parent: adxDatabase
  name: 'watcherIdentityAdmin'
  properties: {
    principalId: managedIdentity.properties.principalId
    principalType: 'App'
    role: 'Admin'
    tenantId: tenant().tenantId
  }
}

// ============================================================================
// Database Watcher
// ============================================================================
resource watcher 'Microsoft.DatabaseWatcher/watchers@2024-10-01-preview' = {
  name: watcherName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    datastore: {
      adxClusterResourceId: adxCluster.id
      kustoClusterDisplayName: adxCluster.name
      kustoClusterUri: adxCluster.properties.uri
      kustoDatabaseName: adxDatabase.name
      kustoManagementUrl: '${adxCluster.properties.uri}/${adxDatabase.name}'
      kustoDataIngestionUri: adxCluster.properties.dataIngestionUri
      kustoOfferingType: 'adx'
    }
  }
}

// ============================================================================
// Database Watcher Target - SQL Database
// ============================================================================
resource watcherTarget 'Microsoft.DatabaseWatcher/watchers/targets@2024-10-01-preview' = {
  parent: watcher
  name: 'target-${sqlDatabaseName}'
  properties: {
    targetType: 'SqlDb'
    sqlDbResourceId: sqlDatabase.id
    connectionServerName: '${sqlServerName}${environment().suffixes.sqlServerHostname}'
    targetAuthenticationType: 'Aad'
    readIntent: false
  }
}

// ============================================================================
// Outputs
// ============================================================================
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabase.name
output adxClusterUri string = adxCluster.properties.uri
output adxDatabaseName string = adxDatabase.name
output watcherName string = watcher.name
output managedIdentityPrincipalId string = managedIdentity.properties.principalId
output managedIdentityClientId string = managedIdentity.properties.clientId
