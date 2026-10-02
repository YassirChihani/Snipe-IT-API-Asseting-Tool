<#
.SYNOPSIS
    Snipe-IT asset tool: scan-based check-in and check-out, bulk CSV changes, caddy audits and reports.

.DESCRIPTION
    Works with Snipe-IT v4.6 and v8. Assets can be scanned or typed by asset tag, serial number,
    or a barcode stored in any other field.

    Modes:
      1  Scan an asset      - scan one asset at a time, see its details, then choose: check in, check out,
                              change status, or repeat the last action
      2  Check out many     - pick a user, location or caddy once, then scan asset after asset
      3  Check in many      - scan assets to check them in, with an optional note
      4  Bulk from CSV      - many check-ins/outs, each to a different person, validated before anything changes
      5  Caddy audit        - compare what's physically in each caddy with Snipe-IT
      6  Reports            - loans, overdue returns, one person's assets, caddy contents

.PARAMETER Mode
    Jump straight to a mode instead of showing the menu: Scan, CheckOut, CheckIn, Csv, Audit or Reports.

.PARAMETER CsvPath
    CSV file for -Mode Csv.

.PARAMETER ResetApiKey
    Forget the stored API key and ask for a new one.

.EXAMPLE
    .\Start-SnipeTool.ps1 -WhatIf
    Practice mode: everything works except the changes to Snipe-IT.

.EXAMPLE
    .\Start-SnipeTool.ps1 -Mode Csv -CsvPath .\loans.csv
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Menu', 'Scan', 'CheckOut', 'CheckIn', 'Csv', 'Audit', 'Reports')][string]$Mode = 'Menu',
    [string]$CsvPath,
    [switch]$ResetApiKey
)

foreach ($lib in 'SnipeApi', 'Ui', 'AssetDesk', 'ScanMode', 'CsvMode', 'CaddyAudit', 'Reports') {
    . (Join-Path $PSScriptRoot "lib/$lib.ps1")
}

$script:Ctx = @{
    Root      = $PSScriptRoot
    Config    = Get-Content (Join-Path $PSScriptRoot 'config/settings.json') -Raw | ConvertFrom-Json
    RunBy     = if ($env:USERNAME) { $env:USERNAME } elseif ($env:USER) { $env:USER } else { 'unknown user' }
    Today     = Get-Date -Format 'yyyy-MM-dd'
    Index     = $null
    Locations = @()
    Statuses  = @()
    History   = [System.Collections.Generic.List[object]]::new()   # changes that can be undone
    AuditUnsupported = $false
    UserCache = @{}
    Version   = ''
}

function Update-AssetCache {
    $assets = Get-AllSnipeAssets
    $script:Ctx.Index = New-AssetIndex -Assets $assets
    $script:Ctx.Locations = @(Get-AllSnipeLocations)
    $script:Ctx.Statuses  = @(Get-AllSnipeStatusLabels)
    Write-Host "Loaded $($assets.Count) assets, $($script:Ctx.Locations.Count) locations and $($script:Ctx.Statuses.Count) status labels." -ForegroundColor Green
}

# --- Connect -------------------------------------------------------------------------------------
Write-Host "`nConnecting to $($script:Ctx.Config.SnipeUrl)..."
try {
    Connect-Snipe -BaseUrl $script:Ctx.Config.SnipeUrl -SkipCertificateCheck:([bool]$script:Ctx.Config.SkipCertificateCheck) -ResetApiKey:$ResetApiKey
}
catch {
    Write-Host "Couldn't connect to Snipe-IT: $($_.Exception.Message)" -ForegroundColor Red
    return
}
$script:Ctx.Version = Get-SnipeVersion
Write-Host "Connected (Snipe-IT $($script:Ctx.Version))." -ForegroundColor Green
Update-AssetCache

# --- Run -------------------------------------------------------------------------------------------
switch ($Mode) {
    'Scan'     { Invoke-AssetDesk; return }
    'CheckOut' { Invoke-ScanCheckout; return }
    'CheckIn'  { Invoke-ScanCheckin; return }
    'Csv'      { Invoke-CsvBulk -CsvPath $CsvPath; return }
    'Audit'    { Invoke-CaddyAudit; return }
    'Reports'  { Invoke-Reports; return }
}

while ($true) {
    Write-Header 'Snipe-IT asset tool'
    Write-Host '  [1] Scan an asset (see details, then check in, check out or change status)'
    Write-Host '  [2] Check out many to one person / place (scan)'
    Write-Host '  [3] Check in many (scan)'
    Write-Host '  [4] Bulk check in / out from CSV'
    Write-Host '  [5] Caddy audit'
    Write-Host '  [6] Reports'
    Write-Host '  [7] Reload assets from Snipe-IT'
    Write-Host '  [Q] Quit'
    $choice = Read-Choice '  Choice' @('1', '2', '3', '4', '5', '6', '7', 'Q')

    try {
        switch ($choice) {
            '1' { Invoke-AssetDesk }
            '2' { Invoke-ScanCheckout }
            '3' { Invoke-ScanCheckin }
            '4' { Invoke-CsvBulk }
            '5' { Invoke-CaddyAudit }
            '6' { Invoke-Reports }
            '7' { Update-AssetCache }
            'Q' { Write-Host 'Goodbye.'; return }
        }
    }
    catch {
        # Anything unexpected returns you to the menu instead of closing the window
        Write-Host "Something went wrong: $($_.Exception.Message)" -ForegroundColor Red
    }
}
