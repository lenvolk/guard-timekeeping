#Requires -Version 5.1
<#
.SYNOPSIS
    Checks that this laptop and the Azure subscription are ready for the timekeeping workshop.

.DESCRIPTION
    Checks the PowerShell, Azure CLI and Bicep versions, the signed-in account, the
    subscription, whether the account can create role assignments, resource provider
    registration, and whether the region offers PostgreSQL Flexible Server B1ms and
    App Service B1 on Linux. Then checks regional quota for the number of teams. Each
    team needs one B1 plan, one B1ms server and one storage account.

    The role check is a warning only. Stage S2 creates role assignments, so the
    runner needs Owner, or Contributor plus Role Based Access Control Administrator.

    Missing parameters are prompted for. Press Enter to accept the default in brackets.
    Runs in Windows PowerShell 5.1 and PowerShell 7. Exits with code 1 if a check fails.

.PARAMETER SubscriptionId
    Subscription to check. Default: the current "az account show" subscription.

.PARAMETER Location
    Azure region name, for example centralus. A portal display name such as
    "Central US" also works. Without it, the script lists suggested regions, shows
    which ones accept a new PostgreSQL server, and asks you to pick one.

.PARAMETER TeamCount
    Number of teams that will deploy in this subscription and region. Default: 1.

.PARAMETER NoRegister
    Report unregistered resource providers instead of registering them.
    deploy.ps1 uses this for stage S0, which changes nothing.

.EXAMPLE
    .\scripts\Test-Prerequisites.ps1

.EXAMPLE
    .\scripts\Test-Prerequisites.ps1 -Location eastus2 -TeamCount 5
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$Location,
    [ValidateRange(0, 50)]
    [int]$TeamCount = 0,
    [switch]$NoRegister
)

$ErrorActionPreference = 'Stop'

$MinAzCliVersion = [version]'2.61.0'
$MinBicepVersion = [version]'0.30.0'
$TestedBicepVersion = [version]'0.48.1'
$DefaultLocation = 'eastus2'
$DefaultTeamCount = 1
$RequiredProviders = @(
    'Microsoft.Web',
    'Microsoft.DBforPostgreSQL',
    'Microsoft.Storage',
    'Microsoft.Insights',
    'Microsoft.OperationalInsights'
)
$DeployAction = 'Microsoft.Resources/deployments/write'
$RoleAssignmentAction = 'Microsoft.Authorization/roleAssignments/write'

$script:Failures = 0
$script:Warnings = 0

function Write-Result {
    param([string]$Status, [string]$Message)
    $colors = @{ PASS = 'Green'; FAIL = 'Red'; WARN = 'Yellow'; INFO = 'Gray' }
    Write-Host ('[{0}] {1}' -f $Status, $Message) -ForegroundColor $colors[$Status]
    if ($Status -eq 'FAIL') { $script:Failures++ }
    if ($Status -eq 'WARN') { $script:Warnings++ }
}

function Read-Value {
    param([string]$Prompt, [string]$Default)
    $answer = Read-Host ('{0} [{1}]' -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

. (Join-Path $PSScriptRoot 'Regions.ps1')

# Runs az and returns stdout as one string. Throws with the az error text on failure.
# Works the same way in Windows PowerShell 5.1 and PowerShell 7.
function Invoke-Az {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & az @args 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    $stdout = @($lines | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $stderr = @($lines | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { $_.Exception.Message } | Where-Object { $_ -and $_ -notmatch '^WARNING:' })
    if ($exitCode -ne 0) {
        $detail = ($stderr -join ' ').Trim()
        if (-not $detail) { $detail = 'no error text' }
        throw ('az {0} failed (exit code {1}): {2}' -f (($args | Select-Object -First 3) -join ' '), $exitCode, $detail)
    }
    return ($stdout -join "`n")
}

function Invoke-AzJson {
    $text = Invoke-Az @args
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Get-FreeQuota {
    param($Usage)
    return ([int64]$Usage.limit - [int64]$Usage.currentValue)
}

# True when any of the caller's effective permissions allows the action. Covers
# built-in and custom roles, group membership and activated PIM roles.
function Test-ActionAllowed {
    param($Permissions, [string]$Action)
    foreach ($permission in @($Permissions)) {
        $allowed = @($permission.actions | Where-Object { $Action -like $_ }).Count -gt 0
        $denied = @($permission.notActions | Where-Object { $Action -like $_ }).Count -gt 0
        if ($allowed -and -not $denied) { return $true }
    }
    return $false
}

Write-Host ''
Write-Host 'Timekeeping workshop: prerequisite check' -ForegroundColor Cyan
Write-Host ''

# --- Laptop tools -----------------------------------------------------------
$psVersion = $PSVersionTable.PSVersion
if ($psVersion -ge [version]'5.1') {
    Write-Result PASS ('PowerShell {0} ({1})' -f $psVersion, $PSVersionTable.PSEdition)
}
else {
    Write-Result FAIL ('PowerShell {0}. Use Windows PowerShell 5.1 or PowerShell 7.' -f $psVersion)
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Result FAIL 'Azure CLI not found. Install it from https://aka.ms/installazurecliwindows, then open a new terminal.'
    exit 1
}

$azVersionInfo = Invoke-AzJson version -o json
$azVersion = [version]$azVersionInfo.'azure-cli'
if ($azVersion -ge $MinAzCliVersion) {
    Write-Result PASS ('Azure CLI {0} (minimum {1})' -f $azVersion, $MinAzCliVersion)
}
else {
    Write-Result FAIL ('Azure CLI {0} is older than {1}. Run: az upgrade' -f $azVersion, $MinAzCliVersion)
}

try {
    $bicepText = Invoke-Az bicep version
    if ($bicepText -match '(\d+\.\d+\.\d+)') {
        $bicepVersion = [version]$Matches[1]
        if ($bicepVersion -lt $MinBicepVersion) {
            Write-Result FAIL ('Bicep {0} is older than {1}. Run: az bicep upgrade' -f $bicepVersion, $MinBicepVersion)
        }
        elseif ($bicepVersion -lt $TestedBicepVersion) {
            Write-Result WARN ('Bicep {0} works, but the templates were tested with {1}. Run: az bicep upgrade' -f $bicepVersion, $TestedBicepVersion)
        }
        else {
            Write-Result PASS ('Bicep {0}' -f $bicepVersion)
        }
    }
    else {
        Write-Result WARN ('Could not read the Bicep version from: {0}' -f $bicepText)
    }
}
catch {
    Write-Result FAIL 'Bicep is not installed for the Azure CLI. Run: az bicep install'
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Result PASS 'git found'
}
else {
    Write-Result INFO 'git not found. That is fine if you downloaded the repository as a zip.'
}

# --- Account and subscription -------------------------------------------------
try {
    $account = Invoke-AzJson account show -o json
}
catch {
    Write-Result FAIL 'Not signed in to Azure. Run: az login'
    exit 1
}
Write-Result PASS ('Signed in as {0} ({1})' -f $account.user.name, $account.user.type)

if (-not $SubscriptionId) {
    Write-Host ('Current subscription: {0} ({1})' -f $account.name, $account.id)
    $SubscriptionId = Read-Value 'Subscription ID' $account.id
}
try {
    Invoke-Az account set --subscription $SubscriptionId | Out-Null
    $account = Invoke-AzJson account show -o json
}
catch {
    Write-Result FAIL ('Cannot use subscription {0}. Check the ID and your access. {1}' -f $SubscriptionId, $_.Exception.Message)
    exit 1
}
Write-Result PASS ('Subscription: {0} ({1})' -f $account.name, $account.id)

# --- Roles (warning only) ------------------------------------------------------------
$roleHelp = 'Deploying needs Owner, or Contributor plus Role Based Access Control Administrator, on the subscription.'
try {
    $permissions = Invoke-AzJson rest --method get --url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01' -f $account.id) --query value -o json
    $canDeploy = Test-ActionAllowed $permissions $DeployAction
    $canAssign = Test-ActionAllowed $permissions $RoleAssignmentAction
    if ($canDeploy -and $canAssign) {
        Write-Result PASS 'Your account can deploy resources and create role assignments'
    }
    elseif ($canDeploy) {
        Write-Result WARN ('Your account can deploy resources but cannot create role assignments, so stage S2 will fail. {0}' -f $roleHelp)
    }
    elseif ($canAssign) {
        Write-Result WARN ('Your account can create role assignments but cannot deploy resources. {0}' -f $roleHelp)
    }
    else {
        Write-Result WARN ('Your account cannot deploy resources or create role assignments. {0} If you use Privileged Identity Management, activate the role first.' -f $roleHelp)
    }
}
catch {
    Write-Result WARN ('Could not read your permissions: {0}. {1}' -f $_.Exception.Message, $roleHelp)
}

$regions = @(Invoke-AzJson account list-locations -o json)
if ($Location) {
    $resolved = Resolve-RegionName $Location $regions
    if (-not $resolved) {
        Write-Result FAIL ('"{0}" is not an Azure region for this subscription. Use a region name such as {1}, or run the script without -Location to pick from a list.' -f $Location, ($SuggestedRegions -join ', '))
        exit 1
    }
    $Location = $resolved
}
else {
    $Location = Read-Region 'Region' $DefaultLocation $account.id $regions
}
$region = $regions | Where-Object { $_.name -eq $Location } | Select-Object -First 1

if ($TeamCount -lt 1) {
    $teamCountText = Read-Value 'Number of teams' $DefaultTeamCount
    $parsed = 0
    if (-not [int]::TryParse($teamCountText, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 50) {
        Write-Result FAIL ('"{0}" is not a team count from 1 to 50.' -f $teamCountText)
        exit 1
    }
    $TeamCount = $parsed
}
Write-Result PASS ('Region: {0} ({1}), quota checked for {2} team(s)' -f $region.name, $region.displayName, $TeamCount)

# --- Resource providers --------------------------------------------------------
foreach ($provider in $RequiredProviders) {
    $state = Invoke-Az provider show --namespace $provider --query registrationState -o tsv
    if ($state -eq 'Registered') {
        Write-Result PASS ('Provider {0} registered' -f $provider)
    }
    elseif ($NoRegister) {
        Write-Result FAIL ('Provider {0} is {1}. Run scripts\Test-Prerequisites.ps1 to register it, or: az provider register --namespace {0}' -f $provider, $state)
    }
    else {
        Write-Host ('Registering {0}. This can take a few minutes...' -f $provider)
        Invoke-Az provider register --namespace $provider --wait | Out-Null
        Write-Result PASS ('Provider {0} registered' -f $provider)
    }
}

# --- Region offers the SKUs ---------------------------------------------------
try {
    $offer = Get-PostgresOffer (Invoke-AzJson postgres flexible-server list-skus --location $Location -o json)
    if ($offer -eq 'Restricted') {
        Write-Result FAIL ('PostgreSQL Flexible Server does not accept new servers in {0} for this subscription. Pick another region (run the script without -Location to see a list), or request region access: see "Prepare a region" in README.md.' -f $Location)
    }
    elseif ($offer -eq 'Ok') {
        Write-Result PASS ('PostgreSQL Flexible Server Burstable B1ms offered in {0}' -f $Location)
    }
    else {
        Write-Result FAIL ('PostgreSQL Flexible Server Burstable B1ms is not offered in {0}.' -f $Location)
    }
}
catch {
    Write-Result FAIL ('Could not read PostgreSQL SKUs for {0}: {1}' -f $Location, $_.Exception.Message)
}

try {
    $appServiceRegions = @(Invoke-AzJson appservice list-locations --sku B1 --linux-workers-enabled -o json)
    if ($appServiceRegions | Where-Object { $_.name -eq $region.displayName }) {
        Write-Result PASS ('App Service B1 on Linux offered in {0}' -f $Location)
    }
    else {
        Write-Result FAIL ('App Service B1 on Linux is not offered in {0}.' -f $Location)
    }
}
catch {
    Write-Result FAIL ('Could not read App Service regions: {0}' -f $_.Exception.Message)
}

# --- Quota for the number of teams ----------------------------------------------
$subscriptionPath = '/subscriptions/{0}' -f $account.id

try {
    $webUsages = Invoke-AzJson rest --method get --url ('{0}/providers/Microsoft.Web/locations/{1}/usages?api-version=2024-11-01' -f $subscriptionPath, $Location) -o json
    foreach ($usageName in @('B1', '*')) {
        $usage = @($webUsages.value) | Where-Object { $_.name.value -eq $usageName } | Select-Object -First 1
        if (-not $usage) {
            Write-Result WARN ('App Service quota "{0}" not reported for {1}.' -f $usageName, $Location)
            continue
        }
        $free = Get-FreeQuota $usage
        $label = $usage.name.localizedValue
        if ($free -ge $TeamCount) {
            Write-Result PASS ('App Service quota {0}: {1} of {2} used, {3} needed' -f $label, $usage.currentValue, $usage.limit, $TeamCount)
        }
        else {
            Write-Result FAIL ('App Service quota {0}: {1} of {2} used, {3} needed. Pick another region, or request a B1 limit of at least {4} for {5}: see "Prepare a region" in README.md.' -f $label, $usage.currentValue, $usage.limit, $TeamCount, ([int64]$usage.currentValue + $TeamCount), $Location)
        }
    }
}
catch {
    Write-Result WARN ('Could not read App Service quota: {0}' -f $_.Exception.Message)
}

try {
    $storageUsage = Invoke-AzJson storage account show-usage --location $Location -o json
    if (-not $storageUsage) {
        Write-Result WARN ('Storage account quota not reported for {0}.' -f $Location)
    }
    else {
        $free = Get-FreeQuota $storageUsage
        if ($free -ge $TeamCount) {
            Write-Result PASS ('Storage accounts: {0} of {1} used, {2} needed' -f $storageUsage.currentValue, $storageUsage.limit, $TeamCount)
        }
        else {
            Write-Result FAIL ('Storage accounts: {0} of {1} used, {2} needed.' -f $storageUsage.currentValue, $storageUsage.limit, $TeamCount)
        }
    }
}
catch {
    Write-Result WARN ('Could not read storage account quota: {0}' -f $_.Exception.Message)
}

try {
    $postgresUsages = Invoke-AzJson rest --method get --url ('{0}/providers/Microsoft.DBforPostgreSQL/locations/{1}/resourceType/flexibleServers/usages?api-version=2025-08-01' -f $subscriptionPath, $Location) -o json
    $relevant = @(@($postgresUsages.value) | Where-Object { $_ -and $_.name.value -match 'Burstable|B1ms|vCore|cores' })
    if ($relevant.Count -eq 0) {
        Write-Result WARN ('PostgreSQL quota is not reported for {0}. Each team needs 1 Burstable vCore. Check Quotas in the Azure portal if you plan many teams.' -f $Location)
    }
    foreach ($usage in $relevant) {
        $free = Get-FreeQuota $usage
        if ($free -ge $TeamCount) {
            Write-Result PASS ('PostgreSQL quota {0}: {1} of {2} used, {3} needed' -f $usage.name.value, $usage.currentValue, $usage.limit, $TeamCount)
        }
        else {
            Write-Result FAIL ('PostgreSQL quota {0}: {1} of {2} used, {3} needed.' -f $usage.name.value, $usage.currentValue, $usage.limit, $TeamCount)
        }
    }
}
catch {
    Write-Result WARN ('Could not read PostgreSQL quota: {0}' -f $_.Exception.Message)
}

Write-Result INFO 'Deploying code needs HTTPS access to *.scm.azurewebsites.net through any corporate proxy.'

# --- Summary --------------------------------------------------------------------
Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host ('{0} check(s) failed, {1} warning(s). Fix the failures above and run the script again.' -f $script:Failures, $script:Warnings) -ForegroundColor Red
    exit 1
}
Write-Host ('All checks passed with {0} warning(s).' -f $script:Warnings) -ForegroundColor Green
exit 0
