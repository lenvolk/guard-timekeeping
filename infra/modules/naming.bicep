// Resource names shared by every stage. Each stage computes the same suffix
// (take(uniqueString(subscription().id, team), 5)) and passes it here, so S2 can
// find what S1 created by name.

@export()
@description('Names of the resource groups and resources for one team.')
type resourceNamesType = {
  dataRg: string
  appRg: string
  postgresServer: string
  postgresDatabase: string
  postgresFirewallRule: string
  storageAccount: string
  signatureContainer: string
  appServicePlan: string
  webApp: string
  apiApp: string
  logAnalytics: string
  appInsights: string
  vnet: string
  nsg: string
  appSubnet: string
  privateEndpointSubnet: string
  storagePrivateEndpoint: string
}

@export()
@description('Returns the resource names for a team. Globally unique names end with the suffix.')
func resourceNames(team string, suffix string) resourceNamesType => {
  dataRg: 'rg-${team}-data'
  appRg: 'rg-${team}-app'
  postgresServer: 'psql-${team}-${suffix}'
  postgresDatabase: 'timekeeping'
  postgresFirewallRule: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
  // Storage names allow lowercase letters and digits only, 24 characters at most.
  // A team name has at most 10 characters, so this has at most 17.
  storageAccount: 'st${team}${suffix}'
  signatureContainer: 'signatures'
  appServicePlan: 'asp-${team}'
  webApp: 'app-${team}-web-${suffix}'
  apiApp: 'app-${team}-api-${suffix}'
  logAnalytics: 'log-${team}'
  appInsights: 'appi-${team}'
  vnet: 'vnet-${team}'
  nsg: 'nsg-${team}'
  appSubnet: 'snet-app'
  privateEndpointSubnet: 'snet-pe'
  storagePrivateEndpoint: 'pe-st${team}${suffix}-blob'
}

@export()
@description('Built-in role definition IDs used by the workshop.')
var roleIds = {
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  storageBlobDataReader: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
}
