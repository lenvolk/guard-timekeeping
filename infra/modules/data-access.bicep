// Runs from S2 in rg-<team>-data. Makes the API's managed identity the PostgreSQL
// Microsoft Entra administrator and grants the storage roles:
//   API identity -> Storage Blob Data Contributor (writes and reads signatures)
//   Runner       -> Storage Blob Data Reader (views signatures in the portal)

import { roleIds } from 'naming.bicep'

param postgresServerName string
param storageAccountName string

@description('Object ID of the API app\'s system-assigned managed identity.')
param apiPrincipalId string

@description('Display name of the API identity. For a system-assigned identity this is the app name, and the API uses it as PGUSER.')
param apiPrincipalName string

@description('Object ID of the person or service principal running deploy.ps1.')
param runnerPrincipalId string

@allowed([
  'User'
  'ServicePrincipal'
])
param runnerPrincipalType string

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' existing = {
  name: postgresServerName
}

resource storage 'Microsoft.Storage/storageAccounts@2026-06-01' existing = {
  name: storageAccountName
}

resource postgresAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2025-08-01' = {
  parent: server
  name: apiPrincipalId
  properties: {
    principalName: apiPrincipalName
    principalType: 'ServicePrincipal'
    tenantId: tenant().tenantId
  }
}

// guid() of scope, principal and role keeps each name stable, so a rerun changes nothing.
resource apiBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, apiPrincipalId, roleIds.storageBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.storageBlobDataContributor)
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Timekeeping API writes and reads guard signatures.'
  }
}

resource runnerBlobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, runnerPrincipalId, roleIds.storageBlobDataReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.storageBlobDataReader)
    principalId: runnerPrincipalId
    principalType: runnerPrincipalType
    description: 'Workshop runner views guard signatures in the Azure portal.'
  }
}

output postgresAdminName string = postgresAdmin.properties.principalName
output apiRoleAssignmentId string = apiBlobContributor.id
output runnerRoleAssignmentId string = runnerBlobReader.id
