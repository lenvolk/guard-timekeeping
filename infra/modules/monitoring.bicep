// Log Analytics workspace and workspace-based Application Insights in rg-<team>-app.

@description('Azure region for both resources.')
param location string

@description('Tags for every resource.')
param tags object

param logAnalyticsName string
param appInsightsName string

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
  }
}

output logAnalyticsName string = logAnalytics.name
output appInsightsName string = appInsights.name
