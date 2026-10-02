# Snipe-IT API helpers and asset lookup.
# Works with Snipe-IT v4.6 and v8 (API v1). Uses only endpoints and fields that exist in both.

$script:Snipe = @{ BaseUrl = $null; Headers = $null; SkipCert = $false }

#region Connection -------------------------------------------------------------------------

# The API key is stored encrypted with Windows DPAPI, so only your Windows account
# on this PC can read it. It is never written into the script or config file.
function Get-SnipeApiKey {
    param([switch]$Reset)
    if ($env:SNIPE_API_KEY) { return $env:SNIPE_API_KEY }   # optional override, e.g. for testing

    $dir  = Join-Path $env:LOCALAPPDATA 'SnipeTools'
    $file = Join-Path $dir 'apikey.xml'
    if ($Reset -and (Test-Path $file)) { Remove-Item $file -Force -WhatIf:$false }
    if (-not (Test-Path $file)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
        $secure = Read-Host 'Paste your Snipe-IT API key (stored encrypted, for your Windows account only)' -AsSecureString
        [pscredential]::new('snipe', $secure) | Export-Clixml -Path $file -WhatIf:$false
    }
    (Import-Clixml -Path $file).GetNetworkCredential().Password
}

function Connect-Snipe {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [switch]$SkipCertificateCheck,
        [switch]$ResetApiKey
    )
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # Windows PowerShell 5.1: make sure TLS 1.2 is allowed
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if ($SkipCertificateCheck) {
            if (-not ('TrustAllCertsPolicy' -as [type])) {
                Add-Type @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
'@
            }
            [Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        }
    }

    $key = Get-SnipeApiKey -Reset:$ResetApiKey
    $script:Snipe.BaseUrl  = $BaseUrl.TrimEnd('/')
    $script:Snipe.SkipCert = [bool]$SkipCertificateCheck
    $script:Snipe.Headers  = @{ Authorization = "Bearer $key"; Accept = 'application/json' }

    $test = Invoke-Snipe -Path 'hardware?limit=1'
    if ($null -eq $test.total) { throw "Connected to $BaseUrl but the response doesn't look like Snipe-IT. Check SnipeUrl in settings.json." }
}

function Invoke-Snipe {
    param(
        [ValidateSet('GET', 'POST', 'PATCH')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body
    )
    $params = @{
        Method      = $Method
        Uri         = '{0}/api/v1/{1}' -f $script:Snipe.BaseUrl, $Path.TrimStart('/')
        Headers     = $script:Snipe.Headers
        ErrorAction = 'Stop'
    }
    if ($Body) {
        $params.Body        = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5))
        $params.ContentType = 'application/json; charset=utf-8'
    }
    if ($script:Snipe.SkipCert -and $PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }

    for ($attempt = 1; ; $attempt++) {
        try { return Invoke-RestMethod @params }
        catch {
            $code = $null
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 429 -and $attempt -lt 6) {
                Write-Host '  Snipe-IT rate limit reached - waiting 15 seconds...' -ForegroundColor DarkYellow
                Start-Sleep -Seconds 15
                continue
            }
            if ($code -eq 401) { throw 'Snipe-IT rejected the API key (401). Run the script with -ResetApiKey to enter a new one.' }
            throw
        }
    }
}

# Snipe-IT often returns HTTP 200 even when an action fails, so check the status field too
function Assert-SnipeSuccess {
    param($Response, [string]$Action)
    if ($Response.status -ne 'success') {
        $msg = if ($Response.messages) { $Response.messages | ConvertTo-Json -Compress -Depth 4 } else { 'no details given' }
        throw "Snipe-IT could not $($Action): $msg"
    }
}

#endregion

#region Assets -------------------------------------------------------------------------------

function ConvertFrom-Html {
    param($Text)
    if ($null -eq $Text) { return $null }
    [System.Net.WebUtility]::HtmlDecode([string]$Text).Trim()
}

# Dates come back as {"date": ...} / {"datetime": ...} objects (v4 and v8) or plain strings
function ConvertTo-SnipeDate {
    param($Value)
    if ($null -eq $Value -or '' -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    $text = if ($Value -is [string]) { $Value } elseif ($Value.date) { $Value.date } elseif ($Value.datetime) { $Value.datetime } else { $null }
    if ($text -is [datetime]) { return $text }
    $d = [datetime]::MinValue
    if ($text -and [datetime]::TryParse([string]$text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    $null
}

# Turns a raw API row into a simpler object used everywhere else
function ConvertTo-AssetInfo {
    param([Parameter(Mandatory)]$Row)

    $custom = @{}
    if ($Row.custom_fields -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Row.custom_fields.PSObject.Properties) {
            $custom[(ConvertFrom-Html $p.Name)] = ConvertFrom-Html $p.Value.value
        }
    }

    $assignedType = $null; $assignedId = $null; $assignedName = $null
    if ($Row.assigned_to) {
        $assignedId   = [int]$Row.assigned_to.id
        $assignedName = ConvertFrom-Html $Row.assigned_to.name
        $assignedType = if ($Row.assigned_to.type) { [string]$Row.assigned_to.type }
                        elseif ($Row.assigned_to.username) { 'user' }
                        else { 'unknown' }
    }

    [pscustomobject]@{
        Id           = [int]$Row.id
        AssetTag     = ConvertFrom-Html $Row.asset_tag
        Name         = ConvertFrom-Html $Row.name
        Serial       = ConvertFrom-Html $Row.serial
        Model        = ConvertFrom-Html $Row.model.name
        Category     = ConvertFrom-Html $Row.category.name
        Status       = ConvertFrom-Html $Row.status_label.name
        StatusId     = [int]$Row.status_label.id
        StatusType   = [string]$Row.status_label.status_type    # deployable / pending / archived / undeployable
        AssignedType = $assignedType                             # user / asset / location / $null
        AssignedId   = $assignedId
        AssignedName = $assignedName
        Location     = ConvertFrom-Html $Row.location.name
        LastCheckout    = ConvertTo-SnipeDate $Row.last_checkout
        ExpectedCheckin = ConvertTo-SnipeDate $Row.expected_checkin
        Custom       = $custom
    }
}

function Get-SnipeAsset {
    param([Parameter(Mandatory)][int]$Id)
    $row = Invoke-Snipe -Path "hardware/$Id"
    if ($row.status -eq 'error') { throw "Asset id $Id not found in Snipe-IT" }
    ConvertTo-AssetInfo $row
}

# Loads every asset once at the start, so scanning is instant and doesn't hammer the API
function Get-AllSnipeAssets {
    $all    = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    do {
        $page = Invoke-Snipe -Path "hardware?limit=500&offset=$offset&sort=id&order=asc"
        $rows = @($page.rows)
        foreach ($r in $rows) { $all.Add((ConvertTo-AssetInfo $r)) }
        $offset += $rows.Count          # Snipe-IT may return fewer than 500 if its limit is set lower
        $pct = [math]::Min(100, [int]($all.Count / [math]::Max(1, [int]$page.total) * 100))
        Write-Progress -Activity 'Loading assets from Snipe-IT' -Status "$($all.Count) of $($page.total)" -PercentComplete $pct
    } while ($rows.Count -gt 0 -and $all.Count -lt [int]$page.total)
    Write-Progress -Activity 'Loading assets from Snipe-IT' -Completed
    $all
}

function Invoke-SnipeCheckin {
    param([Parameter(Mandatory)][int]$AssetId, [string]$Note, [int]$LocationId)
    $body = @{ note = $Note }
    if ($LocationId) { $body.location_id = $LocationId }
    $r = Invoke-Snipe -Method POST -Path "hardware/$AssetId/checkin" -Body $body
    Assert-SnipeSuccess $r "check in asset $AssetId"
}

# Works the same on v4 and v8: checkout_to_type plus assigned_user / assigned_location / assigned_asset
function Invoke-SnipeCheckout {
    param(
        [Parameter(Mandatory)][int]$AssetId,
        [Parameter(Mandatory)][ValidateSet('user', 'location', 'asset')][string]$TargetType,
        [Parameter(Mandatory)][int]$TargetId,
        [string]$Note,
        $ExpectedCheckin
    )
    $body = @{ checkout_to_type = $TargetType; note = $Note }
    $body["assigned_$TargetType"] = $TargetId
    if ($ExpectedCheckin) { $body.expected_checkin = ([datetime]$ExpectedCheckin).ToString('yyyy-MM-dd') }
    $r = Invoke-Snipe -Method POST -Path "hardware/$AssetId/checkout" -Body $body
    Assert-SnipeSuccess $r "check out asset $AssetId"
}

#endregion

#region Users, locations and version ----------------------------------------------------------

# Users are searched on demand rather than all loaded, because an organisation can have thousands
function Find-SnipeUsers {
    param([Parameter(Mandatory)][string]$Search)
    $r = Invoke-Snipe -Path ('users?limit=25&search={0}' -f [uri]::EscapeDataString($Search))
    foreach ($u in @($r.rows)) {
        [pscustomobject]@{
            Id          = [int]$u.id
            Name        = ConvertFrom-Html $u.name
            Username    = ConvertFrom-Html $u.username
            Email       = ConvertFrom-Html $u.email
            EmployeeNum = ConvertFrom-Html $u.employee_num
        }
    }
}

function Get-AllSnipeLocations {
    $all = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    do {
        $page = Invoke-Snipe -Path "locations?limit=500&offset=$offset&sort=id&order=asc"
        $rows = @($page.rows)
        foreach ($l in $rows) { $all.Add([pscustomobject]@{ Id = [int]$l.id; Name = ConvertFrom-Html $l.name }) }
        $offset += $rows.Count
    } while ($rows.Count -gt 0 -and $all.Count -lt [int]$page.total)
    $all
}

# Status labels, e.g. Ready to Deploy (deployable), Broken (undeployable), Disposed (archived)
function Get-AllSnipeStatusLabels {
    $r = Invoke-Snipe -Path 'statuslabels?limit=500'
    foreach ($s in @($r.rows)) {
        [pscustomobject]@{ Id = [int]$s.id; Name = ConvertFrom-Html $s.name; Type = [string]$s.type }
    }
}

function Set-SnipeAssetStatus {
    param([Parameter(Mandatory)][int]$AssetId, [Parameter(Mandatory)][int]$StatusId)
    $r = Invoke-Snipe -Method PATCH -Path "hardware/$AssetId" -Body @{ status_id = $StatusId }
    Assert-SnipeSuccess $r "change the status of asset $AssetId"
}

# Records that an asset was physically seen today (Snipe-IT's built-in audit).
# Snipe-IT works out the next audit date from its own settings.
function Invoke-SnipeAudit {
    param([Parameter(Mandatory)][string]$AssetTag, [string]$Note)
    $r = Invoke-Snipe -Method POST -Path 'hardware/audit' -Body @{ asset_tag = $AssetTag; note = $Note }
    Assert-SnipeSuccess $r "record an audit for $AssetTag"
}

# The version endpoint only exists from v5 onwards
function Get-SnipeVersion {
    try {
        $v = Invoke-Snipe -Path 'version'
        if ($v.version) { return [string]$v.version }
    }
    catch { }
    'v4 or older'
}

#endregion

#region Finding assets from a scan ----------------------------------------------------------

function Add-IndexEntry {
    param([hashtable]$Table, [string]$Key, $Asset, [string]$Field)
    if (-not $Key) { return }
    $Key = $Key.Trim()
    if (-not $Table.ContainsKey($Key)) { $Table[$Key] = [System.Collections.Generic.List[object]]::new() }
    $Table[$Key].Add([pscustomobject]@{ Asset = $Asset; Field = $Field })
}

# Lookup tables (case-insensitive) so each scan is matched instantly
function New-AssetIndex {
    param([Parameter(Mandatory)]$Assets)
    $index = @{ ById = @{}; ByTag = @{}; BySerial = @{}; ByOther = @{} }
    foreach ($a in $Assets) {
        $index.ById[$a.Id] = $a
        Add-IndexEntry $index.ByTag    $a.AssetTag $a 'Asset tag'
        Add-IndexEntry $index.BySerial $a.Serial   $a 'Serial'
        Add-IndexEntry $index.ByOther  $a.Name     $a 'Name'
        foreach ($field in $a.Custom.Keys) { Add-IndexEntry $index.ByOther $a.Custom[$field] $a $field }
    }
    $index
}

function Update-AssetIndex {
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory)]$Asset)
    $existing = $Index.ById[$Asset.Id]
    if ($existing) {
        # Update in place so every lookup table sees the new assignment
        foreach ($p in 'AssignedType', 'AssignedId', 'AssignedName', 'Location', 'Status', 'StatusId', 'StatusType', 'LastCheckout', 'ExpectedCheckin') { $existing.$p = $Asset.$p }
    }
}

function Test-ContainsText {
    param([string]$Text, [string]$Value)
    $Text -and $Text.IndexOf($Value, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

# Order: asset tag -> serial -> name and custom fields. Exact matches only;
# partial matches are returned as suggestions but never used automatically.
function Find-Asset {
    param([Parameter(Mandatory)]$Index, [string]$Value)
    $v = "$Value".Trim()
    $found = @()
    if ($v) {
        foreach ($table in $Index.ByTag, $Index.BySerial, $Index.ByOther) {
            if ($table.ContainsKey($v)) { $found = @($table[$v]); break }
        }
    }
    # The same asset can match through two fields - keep one entry per asset
    $found = @($found | Group-Object { $_.Asset.Id } | ForEach-Object { $_.Group[0] })

    $partial = @()
    if ($found.Count -eq 0 -and $v.Length -ge 4) {
        $partial = @($Index.ById.Values | Where-Object {
            (Test-ContainsText $_.AssetTag $v) -or (Test-ContainsText $_.Serial $v) -or (Test-ContainsText $_.Name $v)
        } | Select-Object -First 5)
    }

    $status = switch ($found.Count) { 0 { 'NotFound' } 1 { 'Found' } default { 'Ambiguous' } }
    [pscustomobject]@{ Status = $status; Matches = $found; Partial = $partial }
}

function Format-AssetLine {
    param($Asset)
    $bits = @($Asset.AssetTag)
    if ($Asset.Name -and $Asset.Name -ne $Asset.AssetTag) { $bits += $Asset.Name }
    if ($Asset.Model)  { $bits += $Asset.Model }
    if ($Asset.Serial) { $bits += "serial $($Asset.Serial)" }
    $bits -join '  |  '
}

# Finds an asset, asking the user only when it can't decide on its own.
# Returns @{ Asset; Field } or $null if skipped.
function Resolve-AssetInteractive {
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory)][string]$Value)
    while ($true) {
        $result = Find-Asset -Index $Index -Value $Value
        if ($result.Status -eq 'Found') { return $result.Matches[0] }

        if ($result.Status -eq 'Ambiguous') {
            Write-Host "  '$Value' matches $($result.Matches.Count) assets:" -ForegroundColor Yellow
            for ($i = 0; $i -lt $result.Matches.Count; $i++) {
                $m = $result.Matches[$i]
                Write-Host ('   [{0}] {1}  (matched {2})' -f ($i + 1), (Format-AssetLine $m.Asset), $m.Field)
            }
            $choice = Read-Host '  Type the number of the right one, or press Enter to skip'
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $result.Matches.Count) {
                return $result.Matches[[int]$choice - 1]
            }
            return $null
        }

        Write-Host "  '$Value' not found as an asset tag, serial, name or custom field." -ForegroundColor Yellow
        foreach ($p in $result.Partial) { Write-Host "   Similar: $(Format-AssetLine $p)" -ForegroundColor DarkGray }
        $Value = Read-Host '  Scan or type another identifier (e.g. the serial on the sticker), or press Enter to skip'
        if (-not $Value) { return $null }
    }
}

#endregion
