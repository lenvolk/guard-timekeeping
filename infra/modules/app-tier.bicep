// S2 resources in rg-<team>-app: the Linux App Service plan, the public web app
// and the API app. The API has a system-assigned managed identity that signs in to
// PostgreSQL and Blob Storage. The API joins the VNet from network.bicep and reaches
// Blob Storage through its private endpoint. PostgreSQL uses its public endpoint.

@description('Azure region for every resource.')
param location string

@description('Tags for every resource.')
param tags object

param planName string
param webAppName string
param apiAppName string

@description('Name of the Application Insights component in this resource group.')
param appInsightsName string

@description('Name of the Log Analytics workspace in this resource group.')
param logAnalyticsName string

@description('Fully qualified PostgreSQL server name.')
param postgresHost string

param postgresDatabase string

@description('Blob endpoint of the signature storage account, for example https://<account>.blob.core.windows.net/')
param storageBlobUrl string

param signatureContainer string

@description('Resource ID of the subnet, delegated to Microsoft.Web/serverFarms, that the API joins.')
param apiSubnetId string

var startupCommand = 'gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8000 main:app'
var diagnosticLogCategories = [
  'AppServiceHTTPLogs'
  'AppServiceConsoleLogs'
  'AppServicePlatformLogs'
]

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsName
}

resource plan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

resource api 'Microsoft.Web/sites@2024-11-01' = {
  name: apiAppName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    // Only private-address traffic enters the VNet. The storage name resolves to the
    // private endpoint through the linked private DNS zone. Other traffic, including
    // PostgreSQL, keeps the default outbound path.
    virtualNetworkSubnetId: apiSubnetId
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      appCommandLine: startupCommand
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      appSettings: [
        {
          name: 'PGHOST'
          value: postgresHost
        }
        {
          name: 'PGPORT'
          value: '5432'
        }
        {
          name: 'PGDATABASE'
          value: postgresDatabase
        }
        {
          // The Entra administrator name. For a system-assigned identity it is the app name.
          name: 'PGUSER'
          value: apiAppName
        }
        {
          name: 'STORAGE_BLOB_URL'
          value: storageBlobUrl
        }
        {
          name: 'SIGNATURE_CONTAINER'
          value: signatureContainer
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
      ]
    }
  }
}

resource web 'Microsoft.Web/sites@2024-11-01' = {
  name: webAppName
  location: location
  tags: tags
  kind: 'app,linux'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      appCommandLine: startupCommand
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      appSettings: [
        {
          name: 'API_BASE_URL'
          value: 'https://${api.properties.defaultHostName}'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
      ]
    }
  }
}

// The laptop deploys with Microsoft Entra sign-in (az webapp deploy), so basic
// publishing credentials stay off.
resource apiScmBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01' = {
  parent: api
  name: 'scm'
  properties: {
    allow: false
  }
}

resource apiFtpBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01' = {
  parent: api
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource webScmBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01' = {
  parent: web
  name: 'scm'
  properties: {
    allow: false
  }
}

resource webFtpBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01' = {
  parent: web
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource apiDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: api
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      for category in diagnosticLogCategories: {
        category: category
        enabled: true
      }
    ]
  }
}

resource webDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: web
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      for category in diagnosticLogCategories: {
        category: category
        enabled: true
      }
    ]
  }
}

output planName string = plan.name
output webAppName string = web.name
output webHostName string = web.properties.defaultHostName
output apiAppName string = api.name
output apiHostName string = api.properties.defaultHostName
output apiPrincipalId string = api.identity.principalId
