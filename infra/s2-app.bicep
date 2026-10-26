// Stage S2: app tier. Creates rg-<team>-app with monitoring, the App Service plan,
// the web app, the API app and a VNet with a private endpoint for the signature
// storage account. Then, through a module scoped to rg-<team>-data,
// makes the API's managed identity the PostgreSQL Entra administrator and creates
// the two storage role assignments.
targetScope = 'subscription'

import { resourceNames } from 'modules/naming.bicep'

@description('Team name: 3 to 10 lowercase letters and digits.')
@minLength(3)
@maxLength(10)
param team string

@description('Azure region for every resource.')
param location string

@description('Object ID of the person or service principal running deploy.ps1. Gets Storage Blob Data Reader.')
param runnerPrincipalId string

@description('Principal type of the runner.')
@allowed([
  'User'
  'ServicePrincipal'
])
param runnerPrincipalType string = 'User'

var suffix = take(uniqueString(subscription().id, team), 5)
var names = resourceNames(team, suffix)
var tags = {
  workload: 'timekeeping-workshop'
  team: team
  environment: 'dev'
}

resource dataRg 'Microsoft.Resources/resourceGroups@2025-04-01' existing = {
  name: names.dataRg
}

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' existing = {
  scope: dataRg
  name: names.postgresServer
}

resource storage 'Microsoft.Storage/storageAccounts@2026-06-01' existing = {
  scope: dataRg
  name: names.storageAccount
}

resource appRg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: names.appRg
  location: location
  tags: tags
}

module monitoring 'modules/monitoring.bicep' = {
  name: '${deployment().name}-monitoring'
  scope: appRg
  params: {
    location: location
    tags: tags
    logAnalyticsName: names.logAnalytics
    appInsightsName: names.appInsights
  }
}

module network 'modules/network.bicep' = {
  name: '${deployment().name}-network'
  scope: appRg
  params: {
    location: location
    tags: tags
    vnetName: names.vnet
    nsgName: names.nsg
    appSubnetName: names.appSubnet
    privateEndpointSubnetName: names.privateEndpointSubnet
    storagePrivateEndpointName: names.storagePrivateEndpoint
    storageAccountId: storage.id
  }
}

module appTier 'modules/app-tier.bicep' = {
  name: '${deployment().name}-apps'
  scope: appRg
  params: {
    location: location
    tags: tags
    planName: names.appServicePlan
    webAppName: names.webApp
    apiAppName: names.apiApp
    appInsightsName: monitoring.outputs.appInsightsName
    logAnalyticsName: monitoring.outputs.logAnalyticsName
    postgresHost: postgresServer.properties.fullyQualifiedDomainName
    postgresDatabase: names.postgresDatabase
    storageBlobUrl: storage.properties.primaryEndpoints.blob
    signatureContainer: names.signatureContainer
    apiSubnetId: network.outputs.appSubnetId
  }
}

module dataAccess 'modules/data-access.bicep' = {
  name: '${deployment().name}-data-access'
  scope: dataRg
  params: {
    postgresServerName: postgresServer.name
    storageAccountName: storage.name
    apiPrincipalId: appTier.outputs.apiPrincipalId
    apiPrincipalName: appTier.outputs.apiAppName
    runnerPrincipalId: runnerPrincipalId
    runnerPrincipalType: runnerPrincipalType
  }
}

output appResourceGroup string = appRg.name
output dataResourceGroup string = dataRg.name
output appServicePlanName string = appTier.outputs.planName
output webAppName string = appTier.outputs.webAppName
output webHostName string = appTier.outputs.webHostName
output apiAppName string = appTier.outputs.apiAppName
output apiHostName string = appTier.outputs.apiHostName
output apiPrincipalId string = appTier.outputs.apiPrincipalId
output postgresServerName string = postgresServer.name
output postgresAdminName string = dataAccess.outputs.postgresAdminName
output storageAccountName string = storage.name
output storageAccountId string = storage.id
output signatureContainerName string = names.signatureContainer
output vnetName string = network.outputs.vnetName
output storagePrivateEndpointName string = network.outputs.storagePrivateEndpointName
output blobPrivateDnsZoneName string = network.outputs.blobPrivateDnsZoneName
output appInsightsName string = monitoring.outputs.appInsightsName
output logAnalyticsName string = monitoring.outputs.logAnalyticsName
