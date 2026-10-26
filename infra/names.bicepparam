// Previews resource names without deploying anything. deploy.ps1 sets the two
// environment variables and runs: az bicep build-params --file infra/names.bicepparam --stdout
// The suffix matches the stage templates, where subscription().id is
// '/subscriptions/<subscription ID>'.
using 'names.bicep'

import { resourceNames } from 'modules/naming.bicep'

var team = readEnvironmentVariable('TK_TEAM', 'team01')
var subscriptionId = readEnvironmentVariable('TK_SUBSCRIPTION_ID', '00000000-0000-0000-0000-000000000000')

param names = resourceNames(team, take(uniqueString('/subscriptions/${subscriptionId}', team), 5))
