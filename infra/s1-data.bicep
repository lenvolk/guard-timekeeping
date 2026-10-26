// Stage S1: data tier. Creates rg-<team>-data with PostgreSQL Flexible Server and
// the storage account for guard signatures.
targetScope = 'subscription'

import { resourceNames } from 'modules/naming.bicep'

@description('Team name: 3 to 10 lowercase letters and digits.')
@minLength(3)
@maxLength(10)
param team string

@description('Azure region for every resource.')
param location string

var suffix = take(uniqueString(subscription().id, team), 5)
var names = resourceNames(team, suffix)
var tags = {
  workload: 'timekeeping-workshop'
  team: team
  environment: 'dev'
}

resource dataRg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: names.dataRg
  location: location
  tags: tags
}

module postgres 'modules/postgres.bicep' = {
  name: '${deployment().name}-postgres'
  scope: dataRg
  params: {
    location: location
    tags: tags
    serverName: names.postgresServer
    databaseName: names.postgresDatabase
    firewallRuleName: names.postgresFirewallRule
  }
}

module storage 'modules/storage.bicep' = {
  name: '${deployment().name}-storage'
  scope: dataRg
  params: {
    location: location
    tags: tags
    storageAccountName: names.storageAccount
    containerName: names.signatureContainer
  }
}

output dataResourceGroup string = dataRg.name
output postgresServerName string = names.postgresServer
output postgresServerFqdn string = postgres.outputs.serverFqdn
output postgresDatabaseName string = names.postgresDatabase
output postgresFirewallRuleName string = names.postgresFirewallRule
output storageAccountName string = names.storageAccount
output storageAccountId string = storage.outputs.storageAccountId
output storageBlobUrl string = storage.outputs.blobEndpoint
output signatureContainerName string = names.signatureContainer
