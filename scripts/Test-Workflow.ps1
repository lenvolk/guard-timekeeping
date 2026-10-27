#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the whole guard workflow, with sign-in and signatures, against the deployed website.

.DESCRIPTION
    Posts to the web form routes the way a browser does, signed in as each person in
    turn, and checks every status code: 303 for an accepted action, 401 or 409 for an
    action the rules reject. Each signature is a small PNG that this script draws.

    It covers the five steps of the transaction chain on the second site, so the first
    site stays as seeded for the attendee walkthrough:
      Identify   A wrong date of birth is rejected. Pages need a sign-in. A guard
                 cannot open the supervisor board.
      Transact   Guard A starts a shift and takes the vacant post (or is already on a post).
                 Guard A starts a lunch break. A wrong cover date of birth is rejected,
                 then guard B covers. Ending the shift during the break is rejected.
                 Guard A returns, hands the post to guard B and ends the shift.
      Sign       Every signed step stores a PNG, its SHA-256 and its meaning.
      Supervise  Guard A requests a time correction. The supervisor approves it.
      Audit      The daily record shows the original and corrected time, every
                 signature verified, and exports as CSV.

    Each run leaves guard B on the post. Later runs start from a guard already on a post.
    The credentials are the synthetic ones in src\api\seed.py and demo.md.

    Runs in Windows PowerShell 5.1 and PowerShell 7. Exits with code 1 on failure.

.PARAMETER WebUrl
    Base URL of the web app, for example https://app-team01-web-abcde.azurewebsites.net

.EXAMPLE
    .\scripts\Test-Workflow.ps1 -WebUrl https://app-team01-web-abcde.azurewebsites.net
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WebUrl
)

$ErrorActionPreference = 'Stop'
$WebUrl = $WebUrl.TrimEnd('/')

Add-Type -AssemblyName System.Net.Http
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

$PngMagic = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

# Synthetic dates of birth from src\api\seed.py, used as passwords for this demo only.
$Credentials = @{
    'G-2001' = '12/02/1987'; 'G-2002' = '04/26/1990'; 'G-2003' = '08/11/1984'
    'G-2004' = '02/19/1992'; 'G-2005' = '10/03/1995'; 'G-2006' = '06/28/1982'
    'S-2001' = '10/10/1983'
}
$Supervisor = 'S-2001'
# --- Signature image ----------------------------------------------------------------

$CrcTable = New-Object 'uint32[]' 256
for ($n = 0; $n -lt 256; $n++) {
    $c = [uint32]$n
    for ($k = 0; $k -lt 8; $k++) {
        if ($c -band 1) { $c = [uint32](3988292384 -bxor ($c -shr 1)) } else { $c = [uint32]($c -shr 1) }
    }
    $CrcTable[$n] = $c
}

function Get-Crc32 {
    param([byte[]]$Bytes)
    $crc = [uint32]4294967295
    foreach ($b in $Bytes) {
        $crc = [uint32]($CrcTable[($crc -bxor $b) -band 255] -bxor ($crc -shr 8))
    }
    return [uint32]($crc -bxor 4294967295)
}

function ConvertTo-BigEndian {
    param([uint32]$Value)
    $bytes = [BitConverter]::GetBytes($Value)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return , $bytes
}

function New-PngChunk {
    param([string]$Type, [byte[]]$Data)
    $typeBytes = [System.Text.Encoding]::ASCII.GetBytes($Type)
    $chunk = New-Object System.IO.MemoryStream
    $length = ConvertTo-BigEndian ([uint32]$Data.Length)
    $chunk.Write($length, 0, 4)
    $chunk.Write($typeBytes, 0, 4)
    $chunk.Write($Data, 0, $Data.Length)
    $crc = ConvertTo-BigEndian (Get-Crc32 ([byte[]]($typeBytes + $Data)))
    $chunk.Write($crc, 0, 4)
    return , $chunk.ToArray()
}

# Draws a wavy line on a white 8-bit grayscale image and returns it as a PNG data URL.
function New-SignatureDataUrl {
    param([int]$Seed = 1)
    $width = 120
    $height = 40
    $stride = $width + 1
    $raw = New-Object 'byte[]' ($stride * $height)
    for ($i = 0; $i -lt $raw.Length; $i++) { $raw[$i] = 255 }
    for ($y = 0; $y -lt $height; $y++) { $raw[$y * $stride] = 0 }
    for ($x = 2; $x -lt $width - 2; $x++) {
        $y = [int][math]::Round($height / 2 + ($height / 3) * [math]::Sin(($x + $Seed * 7) / 9.0))
        foreach ($dy in 0, 1) {
            $row = [math]::Min($height - 1, $y + $dy)
            $raw[$row * $stride + 1 + $x] = 30
        }
    }

    $deflated = New-Object System.IO.MemoryStream
    $deflater = New-Object System.IO.Compression.DeflateStream($deflated, [System.IO.Compression.CompressionMode]::Compress, $true)
    $deflater.Write($raw, 0, $raw.Length)
    $deflater.Dispose()
    [int64]$a = 1
    [int64]$b = 0
    foreach ($byte in $raw) {
        $a = ($a + $byte) % 65521
        $b = ($b + $a) % 65521
    }
    $zlib = New-Object System.IO.MemoryStream
    $zlib.WriteByte(0x78)
    $zlib.WriteByte(0x9C)
    $body = $deflated.ToArray()
    $zlib.Write($body, 0, $body.Length)
    $adler = ConvertTo-BigEndian ([uint32](($b * 65536) + $a))
    $zlib.Write($adler, 0, 4)

    $header = New-Object System.IO.MemoryStream
    $header.Write((ConvertTo-BigEndian ([uint32]$width)), 0, 4)
    $header.Write((ConvertTo-BigEndian ([uint32]$height)), 0, 4)
    $header.Write([byte[]](8, 0, 0, 0, 0), 0, 5)

    $png = New-Object System.IO.MemoryStream
    $png.Write($PngMagic, 0, 8)
    foreach ($chunk in @(
            (New-PngChunk 'IHDR' $header.ToArray()),
            (New-PngChunk 'IDAT' $zlib.ToArray()),
            (New-PngChunk 'IEND' (New-Object 'byte[]' 0)))) {
        $png.Write($chunk, 0, $chunk.Length)
    }
    return 'data:image/png;base64,' + [Convert]::ToBase64String($png.ToArray())
}


# --- HTTP helpers ------------------------------------------------------------------------

# A new client per person, so each sign-in has its own session cookie.
function New-Session {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.CookieContainer = New-Object System.Net.CookieContainer
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(100)
    return $client
}

$script:Http = New-Session

function Invoke-Page {
    param([string]$Method, [string]$Path, [hashtable]$Form)
    $url = '{0}{1}' -f $WebUrl, $Path
    if ($Method -eq 'GET') {
        $response = $script:Http.GetAsync($url).GetAwaiter().GetResult()
    }
    else {
        $pairs = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]'
        foreach ($key in $Form.Keys) {
            $pairs.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' -ArgumentList $key, ([string]$Form[$key])))
        }
        $content = New-Object System.Net.Http.FormUrlEncodedContent -ArgumentList (, $pairs)
        $response = $script:Http.PostAsync($url, $content).GetAwaiter().GetResult()
    }
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $contentType = ''
    if ($response.Content.Headers.ContentType) { $contentType = $response.Content.Headers.ContentType.MediaType }
    $location = ''
    if ($response.Headers.Location) { $location = $response.Headers.Location.ToString() }
    return [pscustomobject]@{
        Status      = [int]$response.StatusCode
        Body        = [System.Text.Encoding]::UTF8.GetString($bytes)
        Bytes       = $bytes
        ContentType = $contentType
        Location    = $location
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

function Get-PageMessage {
    param([string]$Html)
    $match = [regex]::Match($Html, '<p class="flash (?:error|notice)"[^>]*>\s*(.*?)\s*</p>', 'Singleline')
    if ($match.Success) { return [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value) }
    return ''
}

function Assert-State {
    param([string]$Name, $Passed, [string]$Detail)
    if (-not $Passed) {
        Write-Host ('  [FAIL] {0}: {1}' -f $Name, $Detail) -ForegroundColor Red
        throw ('Check failed: {0}' -f $Name)
    }
    Write-Host '  [PASS] ' -ForegroundColor Green -NoNewline
    Write-Host $Name
}

function Invoke-Step {
    param([string]$Name, [string]$Path, [hashtable]$Form, [int]$Expected)
    $response = Invoke-Page POST $Path $Form
    $message = Get-PageMessage $response.Body
    if ($response.Status -ne $Expected) {
        Write-Host ('  [FAIL] {0}: expected HTTP {1}, got {2}. {3}' -f $Name, $Expected, $response.Status, $message) -ForegroundColor Red
        throw ('Step failed: {0}' -f $Name)
    }
    Write-Host '  [PASS] ' -ForegroundColor Green -NoNewline
    if ($Expected -ge 400) { Write-Host ('{0} (HTTP {1}: {2})' -f $Name, $Expected, $message) }
    else { Write-Host ('{0} (HTTP {1})' -f $Name, $Expected) }
    return $response
}

# Signs in with a fresh session and returns where the app sent this person.
function Use-Person {
    param([string]$Badge)
    $script:Http.Dispose()
    $script:Http = New-Session
    $response = Invoke-Page POST '/signin' @{ badge = $Badge; dob = $Credentials[$Badge]; next = '' }
    if ($response.Status -ne 303) { throw ('Sign-in as {0} failed: HTTP {1}. {2}' -f $Badge, $response.Status, (Get-PageMessage $response.Body)) }
    Write-Host ('  Signed in as {0}' -f $Badge) -ForegroundColor Gray
    return $response.Location
}

function Get-Board {
    param([string]$SiteId)
    $page = Invoke-Page GET ('/supervisor/{0}' -f $SiteId)
    if ($page.Status -ne 200) { throw ('Supervisor board for site {0} returned HTTP {1}.' -f $SiteId, $page.Status) }
    return [pscustomobject]@{
        Posts       = @(Get-DataAttributes $page.Body 'post')
        Guards      = @(Get-DataAttributes $page.Body 'guard')
        Adjustments = @(Get-DataAttributes $page.Body 'attention-item adjustment')
    }
}

function Get-GuardCard {
    param([string]$GuardId)
    $page = Invoke-Page GET ('/guard/{0}' -f $GuardId)
    if ($page.Status -ne 200) { throw ('Guard page {0} returned HTTP {1}.' -f $GuardId, $page.Status) }
    $card = @(Get-DataAttributes $page.Body 'guard-card') | Select-Object -First 1
    $events = @([regex]::Matches($page.Body, '<li data-event-id="(\d+)" data-event-type="([a-z_]+)"') |
        ForEach-Object { [pscustomobject]@{ Id = $_.Groups[1].Value; Type = $_.Groups[2].Value } })
    return [pscustomobject]@{ Card = $card; Events = $events }
}

function Get-GuardBy {
    param($Board, [string]$State, [string[]]$Exclude)
    return @($Board.Guards | Where-Object { $_['data-guard-state'] -eq $State -and $Exclude -notcontains $_['data-guard-id'] }) | Select-Object -First 1
}

# --- Workflow ------------------------------------------------------------------------------

Write-Host ('Workflow test against {0}' -f $WebUrl)
try {
    Write-Host 'Identify'
    $status = Invoke-Page GET '/status'
    Assert-State 'Status page reports the API, database and storage are up' ($status.Status -eq 200) ('HTTP {0}' -f $status.Status)
    $anonymous = Invoke-Page GET '/guard/1'
    Assert-State 'A guard page without sign-in redirects to the sign-in page' ($anonymous.Status -eq 303 -and $anonymous.Location -like '/signin*') ('HTTP {0} to {1}' -f $anonymous.Status, $anonymous.Location)
    $null = Invoke-Step 'Rejected: sign in with a wrong date of birth' '/signin' @{ badge = 'G-2001'; dob = '01/01/2000'; next = '' } 401

    $landing = Use-Person $Supervisor
    $siteId = ($landing -split '/')[-1]
    Assert-State ('Supervisor {0} lands on the board for site {1}' -f $Supervisor, $siteId) ($landing -match '^/supervisor/\d+$') $landing
    $board = Get-Board $siteId

    $vacant = @($board.Posts | Where-Object { $_['data-post-state'] -eq 'vacant' }) | Select-Object -First 1
    if ($vacant) {
        $guardA = Get-GuardBy $board 'off-shift' @()
    }
    else {
        $guardA = Get-GuardBy $board 'on-post' @()
        Write-Host '  No vacant post left, so guard A starts on a post and "take a post" is skipped.' -ForegroundColor Yellow
    }
    if (-not $guardA) { throw 'No guard is free to run the workflow on this site.' }
    $aId = $guardA['data-guard-id']; $aBadge = $guardA['data-badge']
    $guardB = Get-GuardBy $board 'available' @($aId)
    $bNeedsShift = $false
    if (-not $guardB) { $guardB = Get-GuardBy $board 'off-shift' @($aId); $bNeedsShift = $true }
    if (-not $guardB) { throw 'No guard can cover or relieve guard A.' }
    $bId = $guardB['data-guard-id']; $bBadge = $guardB['data-badge']
    $witness = @($board.Guards | Where-Object { @($aId, $bId) -notcontains $_['data-guard-id'] })[0]['data-guard-id']
    Write-Host ('  Guard A {0}, cover and relief guard B {1}' -f $aBadge, $bBadge)

    Write-Host 'Transact and sign'
    if ($bNeedsShift) {
        $null = Use-Person $bBadge
        $null = Invoke-Step ('{0} starts a shift with a signature' -f $bBadge) ('/guard/{0}/start-shift' -f $bId) @{ witness_guard_id = $aId; equipment_on = 'on'; signature = (New-SignatureDataUrl 4) } 303
    }
    $null = Use-Person $aBadge
    $forbidden = Invoke-Page GET ('/supervisor/{0}' -f $siteId)
    Assert-State 'A guard cannot open the supervisor board' ($forbidden.Status -eq 403) ('HTTP {0}' -f $forbidden.Status)
    if ($vacant) {
        $null = Invoke-Step ('{0} starts a shift with a signature' -f $aBadge) ('/guard/{0}/start-shift' -f $aId) @{ witness_guard_id = $witness; equipment_on = 'on'; signature = (New-SignatureDataUrl 1) } 303
        $null = Invoke-Step ('{0} takes the vacant post' -f $aBadge) ('/guard/{0}/take-post' -f $aId) @{ post_id = $vacant['data-post-id'] } 303
    }
    $null = Invoke-Step ('Rejected: lunch break with a wrong date of birth for cover guard {0}' -f $bBadge) ('/guard/{0}/break' -f $aId) @{ break_type = 'lunch'; cover_guard_id = $bId; cover_dob = '01/01/2000'; signature = (New-SignatureDataUrl 2) } 401
    $null = Invoke-Step ('{0} starts a lunch break, {1} covers and signs' -f $aBadge, $bBadge) ('/guard/{0}/break' -f $aId) @{ break_type = 'lunch'; cover_guard_id = $bId; cover_dob = $Credentials[$bBadge]; signature = (New-SignatureDataUrl 2) } 303
    $onBreak = Get-GuardCard $aId
    Assert-State ('{0} shows as on break' -f $aBadge) ($onBreak.Card['data-guard-state'] -eq 'on-break' -and $onBreak.Card['data-break-id']) $onBreak.Card['data-guard-state']
    $null = Invoke-Step 'Rejected: end the shift during the break' ('/guard/{0}/end-shift' -f $aId) @{ equipment_off = 'on'; signature = (New-SignatureDataUrl 5) } 409
    $null = Invoke-Step ('{0} returns from the break with a signature' -f $aBadge) ('/guard/{0}/return' -f $aId) @{ break_id = $onBreak.Card['data-break-id']; signature = (New-SignatureDataUrl 6) } 303
    $back = Get-GuardCard $aId
    Assert-State ('{0} is back on the post' -f $aBadge) ($back.Card['data-guard-state'] -eq 'on-post') $back.Card['data-guard-state']
    $null = Invoke-Step ('{0} hands the post to {1}, who confirms and signs' -f $aBadge, $bBadge) ('/assignment/{0}/relieve' -f $back.Card['data-assignment-id']) @{ guard_id = $aId; relief_guard_id = $bId; relief_dob = $Credentials[$bBadge]; signature = (New-SignatureDataUrl 3) } 303
    $null = Invoke-Step ('{0} ends the shift with a signature' -f $aBadge) ('/guard/{0}/end-shift' -f $aId) @{ equipment_off = 'on'; signature = (New-SignatureDataUrl 5) } 303

    Write-Host 'Supervise'
    $ended = (Get-GuardCard $aId).Events | Where-Object { $_.Type -eq 'shift_ended' } | Select-Object -First 1
    Assert-State 'The end of shift appears in recent activity' ([bool]$ended) 'no shift_ended event'
    $form = Invoke-Page GET ('/guard/{0}/correct/{1}' -f $aId, $ended.Id)
    $recorded = [regex]::Match($form.Body, 'name="proposed_time" type="time" value="(\d{2}):(\d{2})"')
    $minutes = [int]$recorded.Groups[1].Value * 60 + [int]$recorded.Groups[2].Value
    $corrected = if ($minutes -ge 2) { $minutes - 2 } else { $minutes + 1 }
    $proposed = '{0:D2}:{1:D2}' -f [int][math]::Floor($corrected / 60), [int]($corrected % 60)
    $null = Invoke-Step ('{0} asks to correct the end of shift to {1}' -f $aBadge, $proposed) ('/guard/{0}/correct/{1}' -f $aId, $ended.Id) @{ proposed_time = $proposed; reason = 'Workflow test: the tablet was busy.' } 303

    $null = Use-Person $Supervisor
    $board = Get-Board $siteId
    $request = @($board.Adjustments | Where-Object { $_['data-event-id'] -eq $ended.Id }) | Select-Object -First 1
    Assert-State 'The correction waits on the supervisor board' ([bool]$request) 'not listed under Needs attention'
    $null = Invoke-Step 'Rejected: reject the correction without a note' ('/adjustments/{0}/decision' -f $request['data-adjustment-id']) @{ site_id = $siteId; decision = 'reject'; note = '' } 400
    $null = Invoke-Step 'The supervisor approves the correction' ('/adjustments/{0}/decision' -f $request['data-adjustment-id']) @{ site_id = $siteId; decision = 'approve'; note = 'Workflow test.' } 303
    $board = Get-Board $siteId
    $post = @($board.Posts | Where-Object { $_['data-guard-id'] -eq $bId }) | Select-Object -First 1
    $aRow = @($board.Guards | Where-Object { $_['data-guard-id'] -eq $aId })[0]
    Assert-State ('The board shows {0} on the post and {1} off shift' -f $bBadge, $aBadge) ($post -and $aRow['data-guard-state'] -eq 'off-shift') ('A is {0}' -f $aRow['data-guard-state'])

    Write-Host 'Audit'
    $audit = Invoke-Page GET ('/audit/{0}' -f $siteId)
    Assert-State 'The daily record opens' ($audit.Status -eq 200) ('HTTP {0}' -f $audit.Status)
    $rows = @(Get-DataAttributes $audit.Body 'audit-row')
    $summary = @(Get-DataAttributes $audit.Body 'audit-summary')[0]
    $correctedRow = @($rows | Where-Object { $_['data-event-id'] -eq $ended.Id })[0]
    Assert-State 'The daily record keeps the original time next to the approved correction' ($correctedRow -and $correctedRow['data-adjustment'] -eq 'approved' -and $correctedRow['data-original'] -ne $correctedRow['data-effective']) 'original or correction missing'
    foreach ($type in 'break_started', 'break_ended', 'post_relieved') {
        Assert-State ('The daily record lists {0}' -f $type) (@($rows | Where-Object { $_['data-event-type'] -eq $type }).Count -ge 1) 'missing'
    }
    Assert-State ('Every signature verifies against its hash ({0} verified)' -f $summary['data-verified']) ([int]$summary['data-verified'] -ge 4 -and [int]$summary['data-problems'] -eq 0) ('{0} verified, {1} problems' -f $summary['data-verified'], $summary['data-problems'])
    $csv = Invoke-Page GET ('/audit/{0}/export.csv' -f $siteId)
    Assert-State 'The daily record exports as CSV' ($csv.Status -eq 200 -and $csv.ContentType -eq 'text/csv' -and $csv.Body -match 'signature_meaning' -and $csv.Body -match ('(?m)^[^,]*,[^,]*,{0},' -f $ended.Id)) ('HTTP {0}, {1}' -f $csv.Status, $csv.ContentType)
    $signed = @($rows | Where-Object { $_['data-signature'] -eq 'verified' })[0]
    $image = Invoke-Page GET ('/signature/{0}' -f $signed['data-event-id'])
    $isPng = $image.Bytes.Length -ge 8
    for ($i = 0; $isPng -and $i -lt 8; $i++) { if ($image.Bytes[$i] -ne $PngMagic[$i]) { $isPng = $false } }
    Assert-State ('Signature for event {0} reads back from Blob Storage as a PNG' -f $signed['data-event-id']) ($image.Status -eq 200 -and $isPng) ('HTTP {0}, {1} bytes' -f $image.Status, $image.Bytes.Length)
    $null = Invoke-Page POST '/signout' @{}
}
catch {
    Write-Host ('Workflow test failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
finally {
    $script:Http.Dispose()
}

Write-Host 'Workflow test passed.' -ForegroundColor Green
exit 0


