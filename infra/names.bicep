// Never deployed. deploy.ps1 builds names.bicepparam against this file to preview
// the resource names before any stage runs, using the same naming function as the
// stage templates.

@description('Resource names for one team, from modules/naming.bicep.')
param names object

output names object = names
