# Region picker shared by deploy.ps1 and scripts\Test-Prerequisites.ps1.
# Dot-source this file. It uses the caller's Invoke-AzJson function.
# Runs in Windows PowerShell 5.1 and PowerShell 7.

# Shown in the menu. Any other region name can still be typed.
$SuggestedRegions = @('eastus', 'eastus2', 'centralus', 'northcentralus', 'southcentralus', 'westus', 'westus2', 'westus3')

# Returns the region name ("centralus") for a name or a portal display name
# ("Central US", "central us"), or $null when it is not a region for this subscription.
function Resolve-RegionName {
    param([string]$Text, $Regions)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $key = ($Text -replace '\s', '').ToLowerInvariant()
    foreach ($region in $Regions) {
        if ($region.name -eq $key -or (($region.displayName -replace '\s', '').ToLowerInvariant() -eq $key)) {
            return $region.name
        }
    }
    return $null
}

# Reads the output of "az postgres flexible-server list-skus" for one region.
# Returns Ok, Restricted (the subscription may not create servers there) or NoB1ms.
function Get-PostgresOffer {
    param($Capabilities)
    $skuNames = @()
    $restricted = $false
    foreach ($capability in @($Capabilities)) {
        $editions = @($capability.supportedServerEditions) + @($capability.supportedFlexibleServerEditions) |
            Where-Object { $_ -and $_.name -eq 'Burstable' }
        foreach ($edition in $editions) {
            $skuNames += @($edition.supportedServerSkus | ForEach-Object { $_.name })
        }
        $restriction = @($capability.supportedFeatures) | Where-Object { $_ -and $_.name -eq 'OfferRestricted' }
        if ($restriction -and $restriction.status -eq 'Enabled') { $restricted = $true }
    }
    if ($restricted) { return 'Restricted' }
    if ($skuNames -contains 'Standard_B1ms') { return 'Ok' }
    return 'NoB1ms'
}

# Checks the regions in parallel, because each lookup takes several seconds.
# Returns a hashtable of region name to Ok, Restricted, NoB1ms or Unknown.
function Get-PostgresRegionStatus {
    param([string[]]$RegionNames, [string]$SubscriptionId)
    $jobs = @{}
    foreach ($name in $RegionNames) {
        $jobs[$name] = Start-Job -ArgumentList $name, $SubscriptionId -ScriptBlock {
            param($location, $subscription)
            $text = & az postgres flexible-server list-skus --location $location --subscription $subscription -o json 2>$null
            if ($LASTEXITCODE -eq 0) { $text -join "`n" }
        }
    }
    $null = $jobs.Values | Wait-Job -Timeout 120
    $status = @{}
    foreach ($name in $RegionNames) {
        $job = $jobs[$name]
        $status[$name] = 'Unknown'
        if ($job.State -eq 'Completed') {
            $text = (Receive-Job $job) -join "`n"
            try {
                if ($text) { $status[$name] = Get-PostgresOffer ($text | ConvertFrom-Json) }
            }
            catch { }
        }
        Remove-Job $job -Force
    }
    return $status
}

# Shows the suggested regions with whether PostgreSQL accepts new servers there,
# then asks for a number, a region name or a display name. Returns the region name.
function Read-Region {
    param([string]$Prompt, [string]$Default, [string]$SubscriptionId, $Regions)
    $menu = @($SuggestedRegions | Where-Object { Resolve-RegionName $_ $Regions })
    if ($Default -and $menu -notcontains $Default -and (Resolve-RegionName $Default $Regions)) { $menu += $Default }

    Write-Host ''
    Write-Host ('   Checking which regions accept a new PostgreSQL server in this subscription ({0} regions, about 15 seconds)...' -f $menu.Count) -ForegroundColor Gray
    $status = Get-PostgresRegionStatus $menu $SubscriptionId
    $labels = @{
        Ok         = 'ok'
        Restricted = 'not available: this subscription cannot create PostgreSQL here'
        NoB1ms     = 'not available: no PostgreSQL B1ms size here'
        Unknown    = 'unknown: the check did not answer, the deployment may still work'
    }
    if ($status[$Default] -ne 'Ok') {
        $firstOk = $menu | Where-Object { $status[$_] -eq 'Ok' } | Select-Object -First 1
        if ($firstOk) { $Default = $firstOk }
    }

    Write-Host ''
    Write-Host ('   {0}' -f $Prompt) -ForegroundColor Cyan
    for ($i = 0; $i -lt $menu.Count; $i++) {
        $name = $menu[$i]
        $display = ($Regions | Where-Object { $_.name -eq $name } | Select-Object -First 1).displayName
        $color = if ($status[$name] -eq 'Ok') { 'Green' } elseif ($status[$name] -eq 'Unknown') { 'Yellow' } else { 'DarkGray' }
        Write-Host ('   [{0}] {1,-16} {2,-18} {3}' -f ($i + 1), $name, $display, $labels[$status[$name]]) -ForegroundColor $color
    }
    Write-Host '   You can also type any other region name, for example canadacentral.' -ForegroundColor Gray

    while ($true) {
        $answer = "$(Read-Host ('   Pick a number or type a region [{0}]' -f $Default))".Trim()
        if ($answer -eq '') { $answer = $Default }
        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $menu.Count) {
            $picked = $menu[$index - 1]
        }
        else {
            $picked = Resolve-RegionName $answer $Regions
        }
        if (-not $picked) {
            Write-Host ('   "{0}" is not a region for this subscription. Type a number from the list, or a name such as centralus.' -f $answer) -ForegroundColor Yellow
            continue
        }
        if ($status.ContainsKey($picked) -and $status[$picked] -ne 'Ok' -and $status[$picked] -ne 'Unknown') {
            Write-Host ('   {0} is {1}. Pick a region marked ok.' -f $picked, $labels[$status[$picked]]) -ForegroundColor Yellow
            continue
        }
        return $picked
    }
}
