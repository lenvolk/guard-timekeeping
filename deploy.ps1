#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys the timekeeping workshop in stages S0 to S4.

.DESCRIPTION
    S0  Preflight. Deploys nothing.
    S1  Data tier: rg-<team>-data with PostgreSQL Flexible Server and the signature storage account.
    S2  App tier: rg-<team>-app with the App Service plan, web app, API app and monitoring,
        plus the PostgreSQL administrator and storage role assignments in rg-<team>-data.
    S3  Code: zips src/web and src/api, deploys them and tests the running app.
    S4  Cleanup: deletes the team's two resource groups.

    The script first asks for a deployment mode:
      Human in the loop (Interactive)  Pauses after each stage for your approval.
      Autopilot                        Runs S0 to S3 without pausing and stops on any failure.
    Cleanup (S4) never runs in Autopilot and always needs the typed team name.

    In Human in the loop mode, missing parameters are prompted for and Enter accepts
    the default in brackets. In Autopilot mode, missing parameters take the saved or
    default values without prompting. The team, subscription and region are saved to
    .deploy/<team>.json (ignored by git), so a resumed run with -Team uses the same values.

    Runs in Windows PowerShell 5.1 and PowerShell 7. Needs only the Azure CLI with Bicep.

.PARAMETER Mode
    Interactive (human in the loop) or Autopilot. Not saved, so each run asks again.

.PARAMETER Team
    Team name: 3 to 10 lowercase letters and digits. Default: team01.

.PARAMETER SubscriptionId
    Default: the current "az account show" subscription.

.PARAMETER Location
    Azure region. Default: eastus2.

.PARAMETER StartAt
    Stage to start from. Default: S0. -StartAt S4 runs cleanup only.

.EXAMPLE
    .\deploy.ps1

.EXAMPLE
    .\deploy.ps1 -Mode Autopilot -Team team03

.EXAMPLE
    .\deploy.ps1 -Team team03 -StartAt S4
#>
[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Autopilot')]
    [string]$Mode,
    [string]$Team,
    [string]$SubscriptionId,
    [string]$Location,
    [ValidateSet('S0', 'S1', 'S2', 'S3', 'S4')]
    [string]$StartAt = 'S0'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
$SettingsDir = Join-Path $RepoRoot '.deploy'
$DefaultTeam = 'team01'
$DefaultLocation = 'eastus2'
$WebApiVersion = '2024-11-01'
$PostgresApiVersion = '2025-08-01'
$ExpectedCounts = @{ sites = '2'; posts = '4'; guards = '12' }
$StorageRetryMinutes = 5

$StageOrder = @('S0', 'S1', 'S2', 'S3', 'S4')
$StageTitles = @{
    S0 = 'Preflight'
    S1 = 'Data tier'
    S2 = 'App tier'
    S3 = 'Code'
    S4 = 'Cleanup'
}

$script:StageFailures = 0
$script:CurrentStage = ''
$script:CheckLog = New-Object System.Collections.ArrayList
$script:WebUrl = ''

# --- Output helpers ---------------------------------------------------------------

function Write-Check {
    param([string]$Name, $Passed, [string]$Detail)
    $ok = [bool]$Passed
    [void]$script:CheckLog.Add([pscustomobject]@{ Stage = $script:CurrentStage; Name = $Name; Passed = $ok; Detail = $Detail })
    if ($ok) {
        Write-Host '  [PASS] ' -ForegroundColor Green -NoNewline
    }
    else {
        Write-Host '  [FAIL] ' -ForegroundColor Red -NoNewline
        $script:StageFailures++
    }
    if ($Detail) { Write-Host ('{0}: {1}' -f $Name, $Detail) } else { Write-Host $Name }
}

function Write-Info {
    param([string]$Message)
    Write-Host ('  {0}' -f $Message) -ForegroundColor Gray
}

function Complete-StageChecks {
    param([string]$Stage)
    if ($script:StageFailures -gt 0) {
        throw ('{0} check(s) failed in {1}. Read the [FAIL] lines above.' -f $script:StageFailures, $Stage)
    }
}

function Write-RunSummary {
    Write-Host ''
    Write-Host '=== Summary ===' -ForegroundColor Cyan
    if ($script:CheckLog.Count -eq 0) {
        Write-Host '  No checks ran.'
    }
    foreach ($stage in $StageOrder) {
        $checks = @($script:CheckLog | Where-Object { $_.Stage -eq $stage })
        if ($checks.Count -eq 0) { continue }
        $failed = @($checks | Where-Object { -not $_.Passed }).Count
        $color = if ($failed -gt 0) { 'Red' } else { 'Green' }
        Write-Host ('  {0} {1}: {2} passed, {3} failed' -f $stage, $StageTitles[$stage], ($checks.Count - $failed), $failed) -ForegroundColor $color
        foreach ($check in $checks | Where-Object { -not $_.Passed }) {
            Write-Host ('      FAIL {0}: {1}' -f $check.Name, $check.Detail) -ForegroundColor Red
        }
    }
    if (-not $script:WebUrl -and $Team) {
        try {
            $s2 = Get-DeploymentOutputs ('tk-{0}-s2' -f $Team)
            $script:WebUrl = 'https://{0}' -f $s2.webHostName
        }
        catch { $script:WebUrl = '' }
    }
    if ($script:WebUrl) {
        Write-Host ''
        Write-Host ('  Website:          {0}' -f $script:WebUrl)
        Write-Host ('  Status page:      {0}/status' -f $script:WebUrl)
        Write-Host ('  Supervisor board: {0}/supervisor/1' -f $script:WebUrl)
    }
}

function Read-Value {
    param([string]$Prompt, [string]$Default)
    if ($Mode -eq 'Autopilot') {
        Write-Host ('{0}: {1} (Autopilot uses the default)' -f $Prompt, $Default)
        return $Default
    }
    $answer = Read-Host ('{0} [{1}]' -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Read-Mode {
    Write-Host 'Deployment mode'
    Write-Host '  [1] Human in the loop: pause after each stage for your approval (default)'
    Write-Host '  [2] Autopilot: deploy everything, stop only on failure'
    while ($true) {
        $answer = "$(Read-Host 'Choose [1]')".Trim()
        switch ($answer) {
            '' { return 'Interactive' }
            '1' { return 'Interactive' }
            '2' { return 'Autopilot' }
        }
        Write-Host 'Type 1 or 2.'
    }
}

function Confirm-Continue {
    param([string]$NextStage)
    while ($true) {
        $answer = Read-Host ('Review the results above. Continue to {0} ({1})? (y/n)' -f $NextStage, $StageTitles[$NextStage])
        switch -Regex ("$answer".Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$' { return $false }
        }
        Write-Host 'Type y or n.'
    }
}

function Get-ResumeCommand {
    param([string]$Stage)
    if ($Stage -eq 'S4') { return ('.\deploy.ps1 -Team {0} -StartAt S4' -f $Team) }
    return ('.\deploy.ps1 -Mode {0} -Team {1} -StartAt {2}' -f $Mode, $Team, $Stage)
}

# --- Azure CLI helpers --------------------------------------------------------------

# Runs az and returns stdout as one string. Throws with the az error text on failure.
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

# Runs a long az command with its progress and errors shown directly in the console.
function Invoke-AzLive {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & az @args
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        throw ('az {0} failed (exit code {1}). The Azure CLI error is shown above.' -f (($args | Select-Object -First 3) -join ' '), $exitCode)
    }
}

function Invoke-StageDeployment {
    param([string]$Stage, [string]$TemplateFile, [string[]]$Parameters)
    $name = 'tk-{0}-{1}' -f $Team, $Stage.ToLowerInvariant()
    Write-Info ('Deployment {0} from {1}' -f $name, $TemplateFile)
    $arguments = @(
        'deployment', 'sub', 'create',
        '--name', $name,
        '--location', $Location,
        '--template-file', (Join-Path $RepoRoot $TemplateFile),
        '--parameters'
    ) + $Parameters + @('--only-show-errors', '--output', 'none')
    Invoke-AzLive @arguments
    return (Get-DeploymentOutputs $name)
}

function Get-DeploymentOutputs {
    param([string]$Name)
    try {
        $raw = Invoke-AzJson deployment sub show --name $Name --query properties.outputs -o json
    }
    catch {
        throw ('Deployment {0} was not found. Run its stage first.' -f $Name)
    }
    if (-not $raw) { throw ('Deployment {0} has no outputs. Run its stage again.' -f $Name) }
    $outputs = @{}
    foreach ($property in $raw.PSObject.Properties) {
        $outputs[$property.Name] = $property.Value.value
    }
    return $outputs
}

function Get-ArmResource {
    param([string]$ResourceId, [string]$ApiVersion)
    return (Invoke-AzJson rest --method get --url ('{0}?api-version={1}' -f $ResourceId, $ApiVersion) -o json)
}

# Object ID and principal type of the signed-in account, as role assignments need them.
function Get-RunnerPrincipal {
    $current = Invoke-AzJson account show -o json
    try {
        if ($current.user.type -eq 'servicePrincipal') {
            $id = Invoke-Az ad sp show --id $current.user.name --query id -o tsv
            return [pscustomobject]@{ Id = $id.Trim(); Type = 'ServicePrincipal' }
        }
        $id = Invoke-Az ad signed-in-user show --query id -o tsv
        return [pscustomobject]@{ Id = $id.Trim(); Type = 'User' }
    }
    catch {
        throw ('Could not read your Microsoft Entra object ID, which S2 needs for the storage role assignment. {0}' -f $_.Exception.Message)
    }
}

# --- HTTP helpers (System.Net.Http works the same in 5.1 and 7) ----------------------

function New-HttpClient {
    Add-Type -AssemblyName System.Net.Http
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(100)
    return $client
}

function Invoke-HttpGet {
    param([string]$Url)
    if (-not $script:Http) { $script:Http = New-HttpClient }
    try {
        $response = $script:Http.GetAsync($Url).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $body; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Status = 0; Body = ''; Error = $_.Exception.GetBaseException().Message }
    }
}

function Get-DataAttributes {
    param([string]$Html, [string]$ClassName)
    $pattern = '<[a-z]+\s+class="(?:[^"]*\s)?' + [regex]::Escape($ClassName) + '(?:\s[^"]*)?"[^>]*>'
    foreach ($element in [regex]::Matches($Html, $pattern)) {
        $attributes = @{}
        foreach ($attribute in [regex]::Matches($element.Value, '(data-[a-z-]+)="([^"]*)"')) {
            $attributes[$attribute.Groups[1].Value] = $attribute.Groups[2].Value
        }
        $attributes
    }
}

# --- Settings ----------------------------------------------------------------------------

function Test-TeamName {
    param([string]$Value)
    return ($Value -cmatch '^[a-z0-9]{3,10}$')
}

function Get-SettingsPath {
    return (Join-Path $SettingsDir ('{0}.json' -f $Team))
}

function Read-Settings {
    $path = Get-SettingsPath
    if (Test-Path $path) { return (Get-Content -Path $path -Raw | ConvertFrom-Json) }
    return $null
}

function Save-Settings {
    if (-not (Test-Path $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir | Out-Null }
    $settings = [ordered]@{
        team           = $Team
        subscriptionId = $SubscriptionId
        location       = $Location
        savedAt        = (Get-Date).ToString('s')
    }
    $settings | ConvertTo-Json | Set-Content -Path (Get-SettingsPath) -Encoding UTF8
}

# --- Zip packaging --------------------------------------------------------------------------

# Compress-Archive in Windows PowerShell 5.1 can write backslashes in entry names,
# which break Linux deployments. Build the zip with forward slashes instead.
function New-DeploymentZip {
    param([string]$SourceDir, [string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $ZipPath) { Remove-Item -Path $ZipPath -Force }
    $root = (Resolve-Path $SourceDir).Path.TrimEnd('\', '/')
    $excluded = @('__pycache__', '.venv', 'venv', '.pytest_cache')
    $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    $count = 0
    try {
        foreach ($file in Get-ChildItem -Path $root -Recurse -File -Force) {
            $relative = $file.FullName.Substring($root.Length + 1)
            $segments = $relative -split '[\\/]'
            $skip = $file.Extension -eq '.pyc'
            foreach ($segment in $segments) {
                if ($excluded -contains $segment) { $skip = $true }
            }
            if ($skip) { continue }
            $entryName = $relative.Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $count++
        }
    }
    finally {
        $zip.Dispose()
    }
    Write-Info ('Packed {0} files from {1}' -f $count, $SourceDir)
}

# --- Stages --------------------------------------------------------------------------------------

function Invoke-S0 {
    $checkScript = Join-Path $RepoRoot 'scripts\Test-Prerequisites.ps1'
    & $checkScript -SubscriptionId $SubscriptionId -Location $Location -TeamCount 1 -NoRegister
    $passed = ($LASTEXITCODE -eq 0)
    Write-Check 'Preflight (scripts\Test-Prerequisites.ps1)' $passed ''
    Complete-StageChecks 'S0'
}

function Invoke-S1 {
    Write-Info 'PostgreSQL usually takes 10 to 15 minutes. Explore the data group in the portal while you wait.'
    $o = Invoke-StageDeployment -Stage 'S1' -TemplateFile 'infra\s1-data.bicep' -Parameters @(
        ('team={0}' -f $Team), ('location={0}' -f $Location))

    Write-Host ''
    $group = Invoke-AzJson group show --name $o.dataResourceGroup -o json
    Write-Check ('Resource group {0}' -f $o.dataResourceGroup) ($group.properties.provisioningState -eq 'Succeeded') $group.location

    $server = Invoke-AzJson postgres flexible-server show --resource-group $o.dataResourceGroup --name $o.postgresServerName -o json
    Write-Check ('PostgreSQL {0} state' -f $o.postgresServerName) ($server.state -eq 'Ready') $server.state
    Write-Check 'PostgreSQL SKU and version' ($server.sku.name -eq 'Standard_B1ms' -and "$($server.version)" -eq '16') ('{0}, PostgreSQL {1}' -f $server.sku.name, $server.version)
    Write-Check 'PostgreSQL password authentication' ($server.authConfig.passwordAuth -eq 'Disabled') $server.authConfig.passwordAuth
    Write-Check 'PostgreSQL Microsoft Entra authentication' ($server.authConfig.activeDirectoryAuth -eq 'Enabled') $server.authConfig.activeDirectoryAuth

    $rule = Invoke-AzJson postgres flexible-server firewall-rule show --resource-group $o.dataResourceGroup --server-name $o.postgresServerName --name $o.postgresFirewallRuleName -o json
    $azureOnly = ($rule.startIpAddress -eq '0.0.0.0') -and ($rule.endIpAddress -eq '0.0.0.0')
    Write-Check ('PostgreSQL firewall rule {0}' -f $o.postgresFirewallRuleName) $azureOnly ('{0} to {1} (Azure services only)' -f $rule.startIpAddress, $rule.endIpAddress)

    $storage = Invoke-AzJson storage account show --resource-group $o.dataResourceGroup --name $o.storageAccountName -o json
    Write-Check ('Storage {0} shared key access' -f $o.storageAccountName) ($storage.allowSharedKeyAccess -eq $false) ('{0}' -f $storage.allowSharedKeyAccess)
    Write-Check 'Storage anonymous blob access' ($storage.allowBlobPublicAccess -eq $false) ('{0}' -f $storage.allowBlobPublicAccess)

    $container = Invoke-AzJson storage container-rm show --resource-group $o.dataResourceGroup --storage-account $o.storageAccountName --name $o.signatureContainerName -o json
    Write-Check ('Container {0}' -f $o.signatureContainerName) ($container -and $container.publicAccess -eq 'None') ('public access {0}' -f $container.publicAccess)
    Complete-StageChecks 'S1'
}

function Invoke-S2 {
    $runner = Get-RunnerPrincipal
    Write-Info ('Runner {0} ({1}) gets Storage Blob Data Reader on the storage account.' -f $runner.Id, $runner.Type)
    $o = Invoke-StageDeployment -Stage 'S2' -TemplateFile 'infra\s2-app.bicep' -Parameters @(
        ('team={0}' -f $Team), ('location={0}' -f $Location),
        ('runnerPrincipalId={0}' -f $runner.Id), ('runnerPrincipalType={0}' -f $runner.Type))
    $script:WebUrl = 'https://{0}' -f $o.webHostName

    Write-Host ''
    $group = Invoke-AzJson group show --name $o.appResourceGroup -o json
    Write-Check ('Resource group {0}' -f $o.appResourceGroup) ($group.properties.provisioningState -eq 'Succeeded') $group.location

    $appGroupId = '/subscriptions/{0}/resourceGroups/{1}' -f $SubscriptionId, $o.appResourceGroup
    foreach ($app in @(@{ Label = 'Web app'; Name = $o.webAppName }, @{ Label = 'API app'; Name = $o.apiAppName })) {
        $site = Get-ArmResource ('{0}/providers/Microsoft.Web/sites/{1}' -f $appGroupId, $app.Name) $WebApiVersion
        Write-Check ('{0} {1}' -f $app.Label, $app.Name) ($site.properties.state -eq 'Running') $site.properties.state
    }

    $principalId = $o.apiPrincipalId
    Write-Check 'API system-assigned managed identity' ([bool]$principalId) $principalId
    $serverId = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{2}' -f $SubscriptionId, $o.dataResourceGroup, $o.postgresServerName
    $admins = Invoke-AzJson rest --method get --url ('{0}/administrators?api-version={1}' -f $serverId, $PostgresApiVersion) -o json
    $admin = @($admins.value) | Where-Object { $_.name -eq $principalId -or $_.properties.objectId -eq $principalId } | Select-Object -First 1
    Write-Check 'API identity is the PostgreSQL Entra administrator' ([bool]$admin) $admin.properties.principalName

    $assignments = @(Invoke-AzJson role assignment list --scope $o.storageAccountId --fill-role-definition-name -o json)
    $apiRole = $assignments | Where-Object { $_.principalId -eq $principalId -and $_.roleDefinitionName -eq 'Storage Blob Data Contributor' } | Select-Object -First 1
    $runnerRole = $assignments | Where-Object { $_.principalId -eq $runner.Id -and $_.roleDefinitionName -eq 'Storage Blob Data Reader' } | Select-Object -First 1
    Write-Check 'Role assignment: API identity, Storage Blob Data Contributor' ([bool]$apiRole) $o.storageAccountName
    Write-Check 'Role assignment: runner, Storage Blob Data Reader' ([bool]$runnerRole) $o.storageAccountName

    $insights = Invoke-AzJson resource show --resource-group $o.appResourceGroup --name $o.appInsightsName --resource-type Microsoft.Insights/components -o json
    Write-Check ('Application Insights {0}' -f $o.appInsightsName) ($insights.properties.provisioningState -eq 'Succeeded') $insights.properties.provisioningState

    Write-Info ('Web app: {0} (no code yet, S3 deploys it)' -f $script:WebUrl)
    Write-Info ('API app: https://{0}' -f $o.apiHostName)
    Complete-StageChecks 'S2'
}

function Invoke-S3 {
    $o = Get-DeploymentOutputs ('tk-{0}-s2' -f $Team)
    $webUrl = 'https://{0}' -f $o.webHostName
    $script:WebUrl = $webUrl
    $workDir = Join-Path $SettingsDir $Team
    if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }
    $apiZip = Join-Path $workDir 'api.zip'
    $webZip = Join-Path $workDir 'web.zip'
    New-DeploymentZip -SourceDir (Join-Path $RepoRoot 'src\api') -ZipPath $apiZip
    New-DeploymentZip -SourceDir (Join-Path $RepoRoot 'src\web') -ZipPath $webZip

    Write-Info ('Deploying the API to {0}. App Service installs requirements.txt, which takes a few minutes.' -f $o.apiAppName)
    Invoke-AzLive webapp deploy --resource-group $o.appResourceGroup --name $o.apiAppName --src-path $apiZip --type zip --only-show-errors --output none
    Write-Info ('Deploying the web app to {0}.' -f $o.webAppName)
    Invoke-AzLive webapp deploy --resource-group $o.appResourceGroup --name $o.webAppName --src-path $webZip --type zip --only-show-errors --output none

    Write-Info 'Waiting for both apps to start and the API to create and seed the tables.'
    $deadline = (Get-Date).AddMinutes(10)
    do {
        $health = Invoke-HttpGet ('{0}/healthz' -f $webUrl)
        if ($health.Status -eq 200) { break }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    Write-Host ''
    Write-Check 'Web /healthz' ($health.Status -eq 200) ('HTTP {0} {1}' -f $health.Status, $health.Error)

    # Wait for the database first. New role assignments can take minutes to apply,
    # so storage then gets its own retry window.
    $deadline = (Get-Date).AddMinutes(10)
    $storageDeadline = $null
    $statusAttributes = @{}
    while ((Get-Date) -lt $deadline) {
        $statusPage = Invoke-HttpGet ('{0}/status' -f $webUrl)
        $statusAttributes = @(Get-DataAttributes $statusPage.Body 'status') | Select-Object -First 1
        if (-not $statusAttributes) { $statusAttributes = @{} }
        if ($statusAttributes['data-database'] -eq 'ok') {
            if ($statusAttributes['data-storage'] -eq 'ok') { break }
            if (-not $storageDeadline) {
                $storageDeadline = (Get-Date).AddMinutes($StorageRetryMinutes)
                $deadline = $storageDeadline
                Write-Info ('Database is up. Waiting up to {0} minutes for the storage role assignment to apply.' -f $StorageRetryMinutes)
            }
        }
        Start-Sleep -Seconds 15
    }
    Write-Check 'Web /status: API responds' ($statusAttributes['data-api'] -eq 'ok') $statusAttributes['data-api']
    Write-Check 'Web /status: database responds' ($statusAttributes['data-database'] -eq 'ok') $statusAttributes['data-database']
    Write-Check 'Web /status: signature storage responds' ($statusAttributes['data-storage'] -eq 'ok') $statusAttributes['data-storage']
    $countsMatch = ($statusAttributes['data-sites'] -eq $ExpectedCounts.sites) -and
        ($statusAttributes['data-posts'] -eq $ExpectedCounts.posts) -and
        ($statusAttributes['data-guards'] -eq $ExpectedCounts.guards)
    Write-Check 'Seed data' $countsMatch ('{0} sites, {1} posts, {2} guards' -f $statusAttributes['data-sites'], $statusAttributes['data-posts'], $statusAttributes['data-guards'])

    if ($script:StageFailures -eq 0) {
        Write-Host ''
        Write-Info 'Running scripts\Test-Workflow.ps1'
        & (Join-Path $RepoRoot 'scripts\Test-Workflow.ps1') -WebUrl $webUrl
        Write-Check 'Test-Workflow.ps1' ($LASTEXITCODE -eq 0) ''
    }
    Complete-StageChecks 'S3'
}

function Remove-ResourceGroups {
    param([string[]]$Names, [int]$TimeoutMinutes)
    $pending = @()
    $attempts = @{}
    foreach ($name in $Names) {
        if ((Invoke-Az group exists --name $name) -eq 'true') {
            Invoke-Az group delete --name $name --yes --no-wait | Out-Null
            $attempts[$name] = 1
            Write-Info ('Deleting {0}' -f $name)
            $pending += $name
        }
        else {
            Write-Check ('{0} does not exist' -f $name) $true
        }
    }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($pending.Count -gt 0) {
        Start-Sleep -Seconds 20
        $stillDeleting = @()
        foreach ($name in $pending) {
            if ((Invoke-Az group exists --name $name) -ne 'true') {
                Write-Check ('{0} deleted' -f $name) $true
                continue
            }
            $state = ''
            try { $state = Invoke-Az group show --name $name --query properties.provisioningState -o tsv } catch { $state = '' }
            if ($state -and $state -ne 'Deleting') {
                # A deletion can fail while Azure finishes another operation. Try again.
                if ($attempts[$name] -ge 3) { throw ('Deleting {0} failed three times. Check it in the portal.' -f $name) }
                $attempts[$name]++
                Write-Info ('Retrying deletion of {0} (attempt {1})' -f $name, $attempts[$name])
                Invoke-Az group delete --name $name --yes --no-wait | Out-Null
            }
            $stillDeleting += $name
        }
        $pending = $stillDeleting
        if ($pending.Count -gt 0) {
            Write-Info ('{0:mm\:ss} still deleting: {1}' -f $timer.Elapsed, ($pending -join ', '))
        }
        if ($timer.Elapsed.TotalMinutes -gt $TimeoutMinutes) {
            throw ('Still deleting after {0} minutes: {1}. Azure keeps deleting in the background.' -f $TimeoutMinutes, ($pending -join ', '))
        }
    }
}

function Invoke-S4 {
    $appGroup = 'rg-{0}-app' -f $Team
    $dataGroup = 'rg-{0}-data' -f $Team
    Write-Host ''
    Write-Host ('This deletes {0} and {1} and everything in them, including every stored signature.' -f $appGroup, $dataGroup) -ForegroundColor Yellow
    $typed = Read-Host ('Type the team name ({0}) to confirm' -f $Team)
    if ("$typed".Trim() -cne $Team) {
        Write-Host 'The name does not match. Nothing was deleted.'
        return $false
    }
    # The role assignments and PostgreSQL administrator in the data group belong to
    # the API identity, so both groups can go at the same time.
    Remove-ResourceGroups -Names @($appGroup, $dataGroup) -TimeoutMinutes 30
    $script:WebUrl = ''
    Write-Check 'Both resource groups deleted' $true
    return $true
}

# --- Main ---------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Timekeeping workshop deployment' -ForegroundColor Cyan
Write-Host ''

$StartAt = $StartAt.ToUpperInvariant()
if ($Mode -eq 'Autopilot' -and $StartAt -eq 'S4') {
    Write-Host 'Cleanup (S4) never runs in Autopilot. Run it without -Mode:' -ForegroundColor Red
    Write-Host '  .\deploy.ps1 -Team <team> -StartAt S4'
    exit 1
}
if (-not $Mode) {
    # Cleanup alone has no stages to approve, so the mode does not matter.
    if ($StartAt -eq 'S4') { $Mode = 'Interactive' } else { $Mode = Read-Mode }
}
$ModeLabel = if ($Mode -eq 'Autopilot') { 'Autopilot' } else { 'Human in the loop' }
Write-Host ''

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host 'Azure CLI not found. Run scripts\Test-Prerequisites.ps1 for help.' -ForegroundColor Red
    exit 1
}

if ($Team) {
    $Team = $Team.Trim().ToLowerInvariant()
    if (-not (Test-TeamName $Team)) {
        Write-Host ('Team name "{0}" must be 3 to 10 lowercase letters and digits.' -f $Team) -ForegroundColor Red
        exit 1
    }
}
else {
    do {
        $Team = (Read-Value 'Team name' $DefaultTeam).ToLowerInvariant()
        if (-not (Test-TeamName $Team)) { Write-Host 'Use 3 to 10 lowercase letters and digits, for example team01.' }
    } until (Test-TeamName $Team)
}

$saved = Read-Settings
if ($saved) {
    Write-Host ('Using saved settings from .deploy\{0}.json' -f $Team)
}

try {
    $account = Invoke-AzJson account show -o json
}
catch {
    Write-Host 'Not signed in to Azure. Run: az login' -ForegroundColor Red
    exit 1
}

if (-not $SubscriptionId) {
    if ($saved -and $saved.subscriptionId) {
        $SubscriptionId = $saved.subscriptionId
    }
    else {
        Write-Host ('Current subscription: {0} ({1})' -f $account.name, $account.id)
        $SubscriptionId = Read-Value 'Subscription ID' $account.id
    }
}
try {
    Invoke-Az account set --subscription $SubscriptionId | Out-Null
    $account = Invoke-AzJson account show -o json
}
catch {
    Write-Host ('Cannot use subscription {0}: {1}' -f $SubscriptionId, $_.Exception.Message) -ForegroundColor Red
    exit 1
}
$SubscriptionId = $account.id

if (-not $Location) {
    if ($saved -and $saved.location) { $Location = $saved.location } else { $Location = Read-Value 'Region' $DefaultLocation }
}
$Location = $Location.Trim().ToLowerInvariant()
if ($saved -and $saved.location -and $saved.location -ne $Location) {
    Write-Host ('Warning: {0} was deployed to {1} before. Resource groups cannot move to {2}.' -f $Team, $saved.location, $Location) -ForegroundColor Yellow
}

Save-Settings

Write-Host ''
Write-Host ('Mode:         {0}' -f $ModeLabel)
Write-Host ('Team:         {0}' -f $Team)
Write-Host ('Subscription: {0} ({1})' -f $account.name, $account.id)
Write-Host ('Region:       {0}' -f $Location)
Write-Host ('Settings:     .deploy\{0}.json' -f $Team)

$targets = @{
    S0 = 'none, checks only'
    S1 = 'rg-{0}-data' -f $Team
    S2 = 'rg-{0}-app, plus the PostgreSQL administrator and storage role assignments in rg-{0}-data' -f $Team
    S3 = 'rg-{0}-app' -f $Team
    S4 = 'rg-{0}-app and rg-{0}-data' -f $Team
}

# Autopilot stops after S3. Cleanup is always a separate, confirmed run.
$lastStage = if ($Mode -eq 'Autopilot') { 'S3' } else { 'S4' }
$startIndex = [array]::IndexOf($StageOrder, $StartAt)
$lastIndex = [array]::IndexOf($StageOrder, $lastStage)

for ($i = $startIndex; $i -le $lastIndex; $i++) {
    $stage = $StageOrder[$i]
    $script:StageFailures = 0
    $script:CurrentStage = $stage
    Write-Host ''
    Write-Host ('=== {0} {1} | target: {2} | mode: {3} ===' -f $stage, $StageTitles[$stage], $targets[$stage], $ModeLabel) -ForegroundColor Cyan
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        switch ($stage) {
            'S0' { Invoke-S0 }
            'S1' { Invoke-S1 }
            'S2' { Invoke-S2 }
            'S3' { Invoke-S3 }
            'S4' {
                if (-not (Invoke-S4)) {
                    Write-RunSummary
                    Write-Host ''
                    Write-Host ('To clean up later: {0}' -f (Get-ResumeCommand 'S4'))
                    exit 0
                }
            }
        }
    }
    catch {
        Write-Host ''
        Write-Host ('{0} failed: {1}' -f $stage, $_.Exception.Message) -ForegroundColor Red
        Write-RunSummary
        Write-Host ''
        Write-Host 'Fix the problem, then resume with:'
        Write-Host ('  {0}' -f (Get-ResumeCommand $stage))
        exit 1
    }
    Write-Host ('{0} finished in {1:mm\:ss}.' -f $stage, $timer.Elapsed) -ForegroundColor Cyan

    if ($Mode -eq 'Interactive' -and $i -lt $StageOrder.Count - 1) {
        $next = $StageOrder[$i + 1]
        Write-Host ''
        if (-not (Confirm-Continue $next)) {
            Write-RunSummary
            Write-Host ''
            Write-Host 'Stopped. Resume with:'
            Write-Host ('  {0}' -f (Get-ResumeCommand $next))
            exit 0
        }
    }
}

Write-RunSummary
Write-Host ''
if ($Mode -eq 'Autopilot') {
    Write-Host 'Autopilot finished. Cleanup (S4) does not run in Autopilot. When you are done, run:' -ForegroundColor Green
    Write-Host ('  {0}' -f (Get-ResumeCommand 'S4'))
}
else {
    Write-Host 'Done.' -ForegroundColor Green
}
exit 0
