<#
.SYNOPSIS
    Fills a TEST Snipe-IT with realistic sample data for trying out the asset tool.

.DESCRIPTION
    Creates categories, models, status labels, locations, test users, 3 laptop caddies and 24 laptops,
    then checks laptops out to caddies and people. It deliberately includes the messy cases the tool
    is built for:
      - a barcode stored in the serial field
      - a barcode stored in a custom field
      - two laptops with the same serial number
      - a broken (non-deployable) laptop
      - two users with the surname Smith
      - an overdue loan and an in-date loan
      - unassigned laptops

    Safe to run more than once: anything that already exists is reused, not duplicated.

    It refuses to run against anything other than localhost, so it can't touch a real Snipe-IT.

.EXAMPLE
    .\tools\New-SnipeTestData.ps1
#>
[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib/SnipeApi.ps1')

$config = Get-Content (Join-Path $root 'config/settings.json') -Raw | ConvertFrom-Json
$uri = [uri]$config.SnipeUrl
if ($uri.Host -notin 'localhost', '127.0.0.1') {
    Write-Host "Refusing to run: SnipeUrl is $($config.SnipeUrl)." -ForegroundColor Red
    Write-Host 'This script only runs against a local test copy (localhost), so it can never add test data to a real system.' -ForegroundColor Red
    return
}

Write-Host "`nAdding test data to $($config.SnipeUrl)" -ForegroundColor Cyan
Connect-Snipe -BaseUrl $config.SnipeUrl

#region Helpers ---------------------------------------------------------------------------------

function New-SnipeItem {
    param([string]$Path, [hashtable]$Body, [string]$What)
    $r = Invoke-Snipe -Method POST -Path $Path -Body $Body
    Assert-SnipeSuccess $r "create $What"
    [int]$r.payload.id
}

# Finds an item by exact name, or creates it. Returns its id.
function Get-OrCreate {
    param([string]$Path, [string]$Name, [hashtable]$Body, [string]$MatchField = 'name')
    $found = Invoke-Snipe -Path ('{0}?limit=50&search={1}' -f $Path, [uri]::EscapeDataString($Name))
    $hit = @($found.rows) | Where-Object { (ConvertFrom-Html $_.$MatchField) -eq $Name } | Select-Object -First 1
    if ($hit) { Write-Host "  exists:  $Path/$Name" -ForegroundColor DarkGray; return [int]$hit.id }
    $id = New-SnipeItem -Path $Path -Body $Body -What "$Path '$Name'"
    Write-Host "  created: $Path/$Name" -ForegroundColor Green
    $id
}

function New-TestPassword {
    -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object { [char]$_ }) + '!9a'
}

#endregion

#region Reference data ----------------------------------------------------------------------------

Write-Host "`nCategories, manufacturers and status labels"
$catLaptop = Get-OrCreate 'categories' 'Laptop'       @{ name = 'Laptop'; category_type = 'asset' }
$catCaddy  = Get-OrCreate 'categories' 'Laptop Caddy' @{ name = 'Laptop Caddy'; category_type = 'asset' }
$mfrDell   = Get-OrCreate 'manufacturers' 'Dell'    @{ name = 'Dell' }
$mfrLap    = Get-OrCreate 'manufacturers' 'LapSafe' @{ name = 'LapSafe' }
$statusOk     = Get-OrCreate 'statuslabels' 'Ready to Deploy' @{ name = 'Ready to Deploy'; type = 'deployable' }
$statusBroken = Get-OrCreate 'statuslabels' 'Broken'          @{ name = 'Broken'; type = 'undeployable' }

# Optional custom field "Barcode", to test finding barcodes stored outside the tag and serial
Write-Host "`nCustom field (Barcode)"
$fieldsetId = $null; $barcodeColumn = $null
try {
    $fieldId = Get-OrCreate 'fields' 'Barcode' @{ name = 'Barcode'; element = 'text'; format = 'ANY' }
    $fieldsetId = Get-OrCreate 'fieldsets' 'Laptop fields' @{ name = 'Laptop fields' }
    $field = Invoke-Snipe -Path "fields/$fieldId"
    $barcodeColumn = if ($field.db_column_name) { $field.db_column_name } else { $field.db_column }
    try { [void](Invoke-Snipe -Method POST -Path "fields/$fieldId/associate" -Body @{ fieldset_id = $fieldsetId; required = $false; order = 1 }) }
    catch { }   # already associated
    if (-not $barcodeColumn) { throw 'could not read the field''s database column name' }
}
catch {
    Write-Host "  Skipped the custom field test: $($_.Exception.Message)" -ForegroundColor DarkYellow
    $fieldsetId = $null; $barcodeColumn = $null
}

Write-Host "`nModels"
$modelBody = @{ name = 'Dell Latitude 3440'; category_id = $catLaptop; manufacturer_id = $mfrDell }
if ($fieldsetId) { $modelBody.fieldset_id = $fieldsetId }
$modelLaptop = Get-OrCreate 'models' 'Dell Latitude 3440' $modelBody
$modelCaddy  = Get-OrCreate 'models' 'LapSafe Diamond' @{ name = 'LapSafe Diamond'; category_id = $catCaddy; manufacturer_id = $mfrLap }

Write-Host "`nLocations"
$locations = @{}
foreach ($name in 'Main Campus - Room B12', 'Main Campus - Room B14', 'North Campus - Library', 'IT Office') {
    $locations[$name] = Get-OrCreate 'locations' $name @{ name = $name }
}

Write-Host "`nTest users"
$users = @{}
foreach ($u in @(
        @('Jane', 'Smith', 'jsmith'), @('John', 'Smith', 'josmith'), @('Amira', 'Hassan', 'ahassan'),
        @('Tom', 'OBrien', 'tobrien'), @('Daniel', 'Okafor', 'dokafor'))) {
    $pw = New-TestPassword
    $users[$u[2]] = Get-OrCreate 'users' $u[2] -MatchField 'username' -Body @{
        first_name = $u[0]; last_name = $u[1]; username = $u[2]; email = "$($u[2])@test.local"
        password = $pw; password_confirmation = $pw; activated = $false
    }
}

#endregion

#region Assets ----------------------------------------------------------------------------------------

Write-Host "`nAssets"
$existing = @{}
foreach ($a in Get-AllSnipeAssets) { $existing[$a.AssetTag] = $a }

function Add-TestAsset {
    param([string]$Tag, [string]$Name, [int]$ModelId, [string]$Serial, [int]$StatusId = $statusOk, [string]$Barcode)
    if ($existing.ContainsKey($Tag)) { Write-Host "  exists:  $Tag" -ForegroundColor DarkGray; return $existing[$Tag].Id }
    $body = @{ asset_tag = $Tag; name = $Name; model_id = $ModelId; status_id = $StatusId; serial = $Serial }
    if ($Barcode -and $barcodeColumn) { $body[$barcodeColumn] = $Barcode }
    $id = New-SnipeItem -Path 'hardware' -Body $body -What "asset $Tag"
    Write-Host "  created: $Tag" -ForegroundColor Green
    $id
}

$caddies = [ordered]@{
    'CAD-01' = Add-TestAsset 'CAD-01' 'Caddy 01' $modelCaddy ''
    'CAD-02' = Add-TestAsset 'CAD-02' 'Caddy 02' $modelCaddy ''
    'CAD-03' = Add-TestAsset 'CAD-03' 'Caddy 03' $modelCaddy ''
}

$laptops = [ordered]@{}
for ($i = 1; $i -le 24; $i++) {
    $tag = 'LT-{0:D4}' -f $i
    $serial = '5CG{0}{1:D3}' -f (Get-Random -Minimum 100 -Maximum 999), $i
    $status = $statusOk
    $barcode = $null
    switch ($i) {
        5 { $serial = '880000123' }          # barcode stored in the serial field
        6 { $barcode = '990000456' }         # barcode stored in the custom field
        7 { $serial = 'DUP-0001' }           # duplicate serial...
        8 { $serial = 'DUP-0001' }           # ...on two laptops
        9 { $status = $statusBroken }        # broken, can't be checked out
    }
    $laptops[$tag] = Add-TestAsset $tag '' $modelLaptop $serial $status $barcode
}

#endregion

#region Check-outs ------------------------------------------------------------------------------------

Write-Host "`nChecking things out"
$fresh = @{}
foreach ($a in Get-AllSnipeAssets) { $fresh[$a.Id] = $a }

function Set-TestCheckout {
    param([int]$AssetId, [string]$Type, [int]$TargetId, [string]$Label, $Due)
    $a = $fresh[$AssetId]
    # Undo any status change made while testing (e.g. marked as Broken), so it can be checked out again
    if ($a.StatusType -and $a.StatusType -ne 'deployable') {
        if ($a.AssignedType) { Invoke-SnipeCheckin -AssetId $AssetId -Note 'Test data reset' }
        Set-SnipeAssetStatus -AssetId $AssetId -StatusId $statusOk
        $a = Get-SnipeAsset -Id $AssetId
    }
    if ($a.AssignedType -eq $Type -and $a.AssignedId -eq $TargetId) { return }
    if ($a.AssignedType) { Invoke-SnipeCheckin -AssetId $AssetId -Note 'Test data reset' }
    try { Invoke-SnipeCheckout -AssetId $AssetId -TargetType $Type -TargetId $TargetId -Note 'Test data' -ExpectedCheckin $Due }
    catch {
        if (-not $Due) { throw }
        # Check-out may reject a date in the past, so check out without one, then set the date on the asset
        Invoke-SnipeCheckout -AssetId $AssetId -TargetType $Type -TargetId $TargetId -Note 'Test data'
        try {
            $r = Invoke-Snipe -Method PATCH -Path "hardware/$AssetId" -Body @{ expected_checkin = ([datetime]$Due).ToString('yyyy-MM-dd') }
            Assert-SnipeSuccess $r "set expected check-in on $($a.AssetTag)"
        }
        catch { Write-Host "  Couldn't set a return date on $($a.AssetTag), so the overdue report will be empty" -ForegroundColor DarkYellow }
    }
    Write-Host "  $($a.AssetTag) -> $Label" -ForegroundColor Green
}

# Caddies live in rooms
Set-TestCheckout $caddies['CAD-01'] 'location' $locations['Main Campus - Room B12'] 'Room B12'
Set-TestCheckout $caddies['CAD-02'] 'location' $locations['Main Campus - Room B14'] 'Room B14'
Set-TestCheckout $caddies['CAD-03'] 'location' $locations['North Campus - Library'] 'North Campus Library'

# Laptops in caddies (LT-0009 is broken so it stays unassigned)
$plan = @{ 'CAD-01' = 1..8; 'CAD-02' = 10..16; 'CAD-03' = 17..20 }
foreach ($caddy in $plan.Keys) {
    foreach ($n in $plan[$caddy]) {
        $tag = 'LT-{0:D4}' -f $n
        Set-TestCheckout $laptops[$tag] 'asset' $caddies[$caddy] $caddy
    }
}

# Laptops that should start unassigned (put back if a test checked them out), and LT-0009 stays Broken
foreach ($n in 9, 23, 24) {
    $id = $laptops['LT-{0:D4}' -f $n]
    $a = $fresh[$id]
    if ($a.AssignedType) { Invoke-SnipeCheckin -AssetId $id -Note 'Test data reset'; Write-Host "  $($a.AssetTag) -> unassigned" -ForegroundColor Green }
    $wanted = if ($n -eq 9) { $statusBroken } else { $statusOk }
    if ($a.Status -ne $(if ($n -eq 9) { 'Broken' } else { 'Ready to Deploy' })) { Set-SnipeAssetStatus -AssetId $id -StatusId $wanted }
}

# Loans to people: one overdue, one in date
Set-TestCheckout $laptops['LT-0021'] 'user' $users['jsmith']  'Jane Smith (overdue)' ((Get-Date).AddDays(-10))
Set-TestCheckout $laptops['LT-0022'] 'user' $users['ahassan'] 'Amira Hassan'          ((Get-Date).AddDays(14))

#endregion

Write-Host @'

Done! What Snipe-IT now says:
  CAD-01 (Room B12):          LT-0001 to LT-0008
  CAD-02 (Room B14):          LT-0010 to LT-0016
  CAD-03 (North Campus Library): LT-0017 to LT-0020
  Jane Smith:   LT-0021 (overdue)      Amira Hassan: LT-0022
  Unassigned:   LT-0009 (Broken), LT-0023, LT-0024

Things to try:
  Caddy audit on CAD-01, scanning: LT-0001, LT-0002, 880000123 (serial barcode), 990000456 (custom field),
    DUP-0001 (pick one), LT-0010 (belongs in CAD-02), LT-0023 (unassigned), LT-0021 (on loan),
    LT-0009 (broken), XYZ-999 (unknown). Don't scan LT-0003 or LT-0004, so they show as missing.
  Check out to user "Smith" - you'll be asked which Smith.
  Reports -> Overdue returns should list LT-0021.
'@ -ForegroundColor Cyan
