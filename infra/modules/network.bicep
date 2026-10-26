// S2 network in rg-<team>-app: a small VNet, a private endpoint for the signature
// storage account and the private DNS zone that resolves it. The API joins the VNet
// through regional VNet integration, so it reaches Blob Storage privately even when
// a policy turns the storage account's public network access off.
// PostgreSQL stays on its public endpoint (Azure services only).

@description('Azure region for every resource.')
param location string

@description('Tags for every resource.')
param tags object

param vnetName string
param nsgName string
param appSubnetName string
param privateEndpointSubnetName string
param storagePrivateEndpointName string

@description('Resource ID of the signature storage account in rg-<team>-data.')
param storageAccountId string

var addressSpace = '10.42.0.0/24'
var appSubnetPrefix = '10.42.0.0/26'
var privateEndpointSubnetPrefix = '10.42.0.64/27'
var blobPrivateDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressSpace
      ]
    }
    subnets: [
      {
        name: appSubnetName
        properties: {
          addressPrefix: appSubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
          delegations: [
            {
              name: 'app-service'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource blobDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: blobPrivateDnsZoneName
  location: 'global'
  tags: tags
}

resource blobDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: blobDnsZone
  name: '${vnetName}-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: storagePrivateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: vnet.properties.subnets[1].id
    }
    privateLinkServiceConnections: [
      {
        name: storagePrivateEndpointName
        properties: {
          privateLinkServiceId: storageAccountId
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource storagePrivateDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: storagePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: blobDnsZone.id
        }
      }
    ]
  }
}

output vnetName string = vnet.name
output appSubnetId string = vnet.properties.subnets[0].id
output storagePrivateEndpointName string = storagePrivateEndpoint.name
output blobPrivateDnsZoneName string = blobDnsZone.name
