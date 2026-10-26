#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the main guard workflow, with signatures, against the deployed website.

.DESCRIPTION
    Posts to the web form routes the way a browser does and checks each status code:
    303 for an accepted action and 409 for an action the rules reject. Each signature
    is a small PNG that this script draws, sent as a data URL in the "signature" field.

    Main path, on a site with a vacant post:
      1. Guard A starts a shift with a witness, equipment on and a signature.
      2. Guard A takes the vacant post.
      3. Rejected: guard A tries to hand the post to a guard who is on another post.
      4. Guard B, who is on shift and off post, accepts the post with a signature.
      5. Guard A ends the shift with equipment off and a signature.
      6. The supervisor board shows the post covered by guard B and guard A off shift.
      7. One signature is read back through the web app and checked as a PNG.

    Each run leaves one more post covered. When no site has a vacant post left, the
    script relieves a guard who is already on a post and skips "take a post". It uses
    the last site first, so the first site stays as seeded for the attendee walkthrough.

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
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$Http = New-Object System.Net.Http.HttpClient($handler)
$Http.Timeout = [TimeSpan]::FromSeconds(100)

$PngMagic = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

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

function Invoke-Page {
    param([string]$Method, [string]$Path, [hashtable]$Form)
    $url = '{0}{1}' -f $WebUrl, $Path
    if ($Method -eq 'GET') {
        $response = $Http.GetAsync($url).GetAwaiter().GetResult()
    }
    else {
        $pairs = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]'
        foreach ($key in $Form.Keys) {
            $pairs.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' -ArgumentList $key, ([string]$Form[$key])))
        }
        $content = New-Object System.Net.Http.FormUrlEncodedContent -ArgumentList (, $pairs)
        $response = $Http.PostAsync($url, $content).GetAwaiter().GetResult()
    }
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $contentType = ''
    if ($response.Content.Headers.ContentType) { $contentType = $response.Content.Headers.ContentType.MediaType }
    return [pscustomobject]@{
        Status      = [int]$response.StatusCode
        Body        = [System.Text.Encoding]::UTF8.GetString($bytes)
        Bytes       = $bytes
        ContentType = $contentType
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

function Get-Board {
    param([string]$SiteId)
    $page = Invoke-Page GET ('/supervisor/{0}' -f $SiteId)
    if ($page.Status -ne 200) { throw ('Supervisor board for site {0} returned HTTP {1}.' -f $SiteId, $page.Status) }
    $events = @([regex]::Matches($page.Body, '<li data-event-id="(\d+)"[^>]*data-has-signature="(true|false)"') |
        ForEach-Object { [pscustomobject]@{ Id = $_.Groups[1].Value; Signed = ($_.Groups[2].Value -eq 'true') } })
    return [pscustomobject]@{
        SiteId = $SiteId
        Posts  = @(Get-DataAttributes $page.Body 'post')
        Guards = @(Get-DataAttributes $page.Body 'guard')
        Events = $events
    }
}

function Get-GuardsInState {
    param($Board, [string]$State)
    return @($Board.Guards | Where-Object { $_['data-guard-state'] -eq $State })
}

function Get-OtherGuard {
    param($Board, [string[]]$Exclude)
    $other = @($Board.Guards | Where-Object { $Exclude -notcontains $_['data-guard-id'] }) | Select-Object -First 1
    if ($other) { return $other['data-guard-id'] }
    return $null
}

function Get-AssignmentId {
    param([string]$GuardId)
    $page = Invoke-Page GET ('/guard/{0}' -f $GuardId)
    $card = @(Get-DataAttributes $page.Body 'guard-card') | Select-Object -First 1
    if (-not $card -or -not $card['data-assignment-id']) { throw ('Guard {0} has no open assignment.' -f $GuardId) }
    return $card['data-assignment-id']
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
    if ($Expected -eq 409) {
        Write-Host ('{0} (HTTP 409: {1})' -f $Name, $message)
    }
    else {
        Write-Host ('{0} (HTTP {1})' -f $Name, $Expected)
    }
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

function Invoke-RejectedRelief {
    param($Board, [string]$AssignmentId, [string]$OnPostGuard, [string]$Signature)
    $busy = @(Get-GuardsInState $Board 'on-post' | Where-Object { $_['data-guard-id'] -ne $OnPostGuard }) | Select-Object -First 1
    if ($busy) {
        $busyId = $busy['data-guard-id']
        Invoke-Step ('Rejected: hand the post to guard {0}, who is on another post' -f $busyId) ('/assignment/{0}/relieve' -f $AssignmentId) @{ guard_id = $OnPostGuard; relief_guard_id = $busyId; signature = $Signature } 409
    }
    else {
        Invoke-Step ('Rejected: guard {0} hands the post to themselves' -f $OnPostGuard) ('/assignment/{0}/relieve' -f $AssignmentId) @{ guard_id = $OnPostGuard; relief_guard_id = $OnPostGuard; signature = $Signature } 409
    }
}

# Returns a guard who is on shift and off post, starting a shift for one if needed.
function Get-ReliefGuard {
    param($Board, [string[]]$Exclude)
    $available = @(Get-GuardsInState $Board 'available' | Where-Object { $Exclude -notcontains $_['data-guard-id'] }) | Select-Object -First 1
    if ($available) { return $available['data-guard-id'] }
    $offShift = @(Get-GuardsInState $Board 'off-shift' | Where-Object { $Exclude -notcontains $_['data-guard-id'] }) | Select-Object -First 1
    if (-not $offShift) { throw 'No guard is free to act as relief.' }
    $relief = $offShift['data-guard-id']
    $witness = Get-OtherGuard $Board (@($relief) + $Exclude)
    if (-not $witness) { $witness = $Exclude[0] }
    Invoke-Step ('Relief guard {0} starts a shift with a signature' -f $relief) ('/guard/{0}/start-shift' -f $relief) @{ witness_guard_id = $witness; equipment_on = 'on'; signature = (New-SignatureDataUrl 4) } 303
    return $relief
}

function Assert-Coverage {
    param([string]$SiteId, [string]$PostId, [string]$CoveredBy, [string]$OffShiftGuard)
    $after = Get-Board $SiteId
    $postAfter = @($after.Posts | Where-Object { $_['data-post-id'] -eq $PostId })[0]
    $guardAfter = @($after.Guards | Where-Object { $_['data-guard-id'] -eq $OffShiftGuard })[0]
    Assert-State ('Supervisor board shows post {0} covered by guard {1}' -f $PostId, $CoveredBy) ($postAfter['data-guard-id'] -eq $CoveredBy) ('covered by {0}' -f $postAfter['data-guard-id'])
    Assert-State ('Supervisor board shows guard {0} off shift' -f $OffShiftGuard) ($guardAfter['data-guard-state'] -eq 'off-shift') $guardAfter['data-guard-state']
    return $after
}

function Assert-SignatureReadBack {
    param($Board)
    $signed = @($Board.Events | Where-Object { $_.Signed }) | Select-Object -First 1
    Assert-State 'Supervisor board lists a signed event' ([bool]$signed) 'no signed events found'
    $image = Invoke-Page GET ('/signature/{0}' -f $signed.Id)
    $isPng = $image.Bytes.Length -ge 8
    for ($i = 0; $isPng -and $i -lt 8; $i++) { if ($image.Bytes[$i] -ne $PngMagic[$i]) { $isPng = $false } }
    $ok = ($image.Status -eq 200) -and ($image.ContentType -eq 'image/png') -and $isPng
    Assert-State ('Signature for event {0} reads back from Blob Storage as a PNG' -f $signed.Id) $ok ('HTTP {0}, {1}, {2} bytes' -f $image.Status, $image.ContentType, $image.Bytes.Length)
}

function Invoke-MainPath {
    param($Board)
    $siteId = $Board.SiteId
    $post = @($Board.Posts | Where-Object { $_['data-post-state'] -eq 'vacant' })[0]
    $postId = $post['data-post-id']
    $guardA = @(Get-GuardsInState $Board 'off-shift')[0]['data-guard-id']
    $witness = Get-OtherGuard $Board @($guardA)
    Write-Host ('Site {0}: guard {1} takes vacant post {2}, then hands it to a relief guard.' -f $siteId, $guardA, $postId)

    Invoke-Step ('Guard {0} starts a shift with a signature' -f $guardA) ('/guard/{0}/start-shift' -f $guardA) @{ witness_guard_id = $witness; equipment_on = 'on'; signature = (New-SignatureDataUrl 1) } 303
    Invoke-Step ('Guard {0} takes post {1}' -f $guardA, $postId) ('/guard/{0}/take-post' -f $guardA) @{ post_id = $postId } 303
    $assignmentId = Get-AssignmentId $guardA

    $current = Get-Board $siteId
    Invoke-RejectedRelief $current $assignmentId $guardA (New-SignatureDataUrl 2)
    $guardB = Get-ReliefGuard $current @($guardA)
    Invoke-Step ('Guard {0} accepts post {1} with a signature' -f $guardB, $postId) ('/assignment/{0}/relieve' -f $assignmentId) @{ guard_id = $guardA; relief_guard_id = $guardB; signature = (New-SignatureDataUrl 3) } 303
    Invoke-Step ('Guard {0} ends the shift with a signature' -f $guardA) ('/guard/{0}/end-shift' -f $guardA) @{ equipment_off = 'on'; signature = (New-SignatureDataUrl 5) } 303

    $after = Assert-Coverage $siteId $postId $guardB $guardA
    Assert-SignatureReadBack $after
}

function Invoke-ReliefPath {
    param($Board)
    $siteId = $Board.SiteId
    $post = @($Board.Posts | Where-Object { $_['data-post-state'] -eq 'covered' })[0]
    $postId = $post['data-post-id']
    $assignmentId = $post['data-assignment-id']
    $onPost = $post['data-guard-id']
    Write-Host 'No site has a vacant post left, so "take a post" is skipped.' -ForegroundColor Yellow
    Write-Host ('Site {0}: a relief guard takes over post {1} from guard {2}.' -f $siteId, $postId, $onPost)

    Invoke-RejectedRelief $Board $assignmentId $onPost (New-SignatureDataUrl 2)
    $relief = Get-ReliefGuard $Board @($onPost)
    Invoke-Step ('Guard {0} accepts post {1} with a signature' -f $relief, $postId) ('/assignment/{0}/relieve' -f $assignmentId) @{ guard_id = $onPost; relief_guard_id = $relief; signature = (New-SignatureDataUrl 3) } 303
    Invoke-Step ('Guard {0} ends the shift with a signature' -f $onPost) ('/guard/{0}/end-shift' -f $onPost) @{ equipment_off = 'on'; signature = (New-SignatureDataUrl 5) } 303

    $after = Assert-Coverage $siteId $postId $relief $onPost
    Assert-SignatureReadBack $after
}

Write-Host ('Workflow test against {0}' -f $WebUrl)
try {
    $status = Invoke-Page GET '/status'
    Assert-State 'Status page reports the API, database and storage are up' ($status.Status -eq 200) ('HTTP {0}' -f $status.Status)

    $homePage = Invoke-Page GET '/'
    $siteIds = @(Get-DataAttributes $homePage.Body 'site' | ForEach-Object { $_['data-site-id'] } |
        Sort-Object { [int]$_ } -Descending)
    Assert-State ('Home page lists {0} sites' -f $siteIds.Count) ($siteIds.Count -gt 0) 'no sites found'

    $boards = @($siteIds | ForEach-Object { Get-Board $_ })
    $free = { param($b) @(Get-GuardsInState $b 'off-shift').Count + @(Get-GuardsInState $b 'available').Count }
    $mainBoard = $boards | Where-Object {
        @($_.Posts | Where-Object { $_['data-post-state'] -eq 'vacant' }).Count -ge 1 -and
        @(Get-GuardsInState $_ 'off-shift').Count -ge 1 -and
        (& $free $_) -ge 2
    } | Select-Object -First 1

    if ($mainBoard) {
        Invoke-MainPath $mainBoard
    }
    else {
        $reliefBoard = $boards | Where-Object {
            @($_.Posts | Where-Object { $_['data-post-state'] -eq 'covered' }).Count -ge 1 -and
            (& $free $_) -ge 1
        } | Select-Object -First 1
        if (-not $reliefBoard) { throw 'No site has the free guards and posts this test needs.' }
        Invoke-ReliefPath $reliefBoard
    }
}
catch {
    Write-Host ('Workflow test failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
finally {
    $Http.Dispose()
}

Write-Host 'Workflow test passed.' -ForegroundColor Green
exit 0
