// S1 PostgreSQL Flexible Server in rg-<team>-data. Microsoft Entra authentication
// only, so no administrator password exists. Public access is on, but the firewall
// allows connections from Azure services only. S2 adds the API's identity as admin.

@description('Azure region for the server.')
param location string

@description('Tags for every resource.')
param tags object

param serverName string
param databaseName string
param firewallRuleName string

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    storage: {
      storageSizeGB: 32
      autoGrow: 'Disabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled'
      tenantId: tenant().tenantId
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// Start and end 0.0.0.0 means "allow Azure services". No rule exists for the laptop.
resource allowAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2025-08-01' = {
  parent: server
  name: firewallRuleName
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2025-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  // The server accepts one change at a time, so create the children in order.
  dependsOn: [
    allowAzureServices
  ]
}

output serverId string = server.id
output serverFqdn string = server.properties.fullyQualifiedDomainName
