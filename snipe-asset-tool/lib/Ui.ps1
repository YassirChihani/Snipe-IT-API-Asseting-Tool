# Shared helpers used by every mode: prompts, finding users/locations, doing a check-in or
# check-out safely, and saving reports. Relies on $script:Ctx set up in Start-SnipeTool.ps1.

#region Prompts ---------------------------------------------------------------------------------

function Write-Header {
    param([string]$Text)
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
    if ($WhatIfPreference) { Write-Host 'PRACTICE MODE (-WhatIf): Snipe-IT will not be changed.' -ForegroundColor Magenta }
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Valid, [string]$Default)
    while ($true) {
        $answer = "$(Read-Host $Prompt)".Trim().ToUpper()
        if (-not $answer -and $Default) { return $Default }
        if ($answer -in $Valid) { return $answer }
        Write-Host "  Please type one of: $($Valid -join ', ')" -ForegroundColor DarkYellow
    }
}

function Read-YesNo {
    param([string]$Prompt)
    (Read-Choice "$Prompt (y/n)" @('Y', 'N')) -eq 'Y'
}

# Accepts dd/MM/yyyy, yyyy-MM-dd or +days (e.g. +14). Empty means no date.
function ConvertTo-DateInput {
    param([string]$Text)
    $t = "$Text".Trim()
    if (-not $t) { return $null }
    if ($t -match '^\+(\d{1,3})$') { return (Get-Date).Date.AddDays([int]$Matches[1]) }
    $formats = [string[]]@('dd/MM/yyyy', 'd/M/yyyy', 'yyyy-MM-dd', 'dd-MM-yyyy', 'dd.MM.yyyy')
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($t, $formats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) {
        return $d
    }
    throw "Couldn't read '$t' as a date. Use dd/MM/yyyy, yyyy-MM-dd or +days (e.g. +14)."
}

function Read-DateInput {
    param([string]$Prompt)
    while ($true) {
        try {
            $d = ConvertTo-DateInput (Read-Host $Prompt)
            if ($d -and $d -lt (Get-Date).Date) { Write-Host '  That date is in the past.' -ForegroundColor DarkYellow; continue }
            return $d
        }
        catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
}

function Format-Date {
    param($Date)
    if ($Date) { ([datetime]$Date).ToString('dd/MM/yyyy') } else { '' }
}

#endregion

#region Labels ----------------------------------------------------------------------------------

function Get-AssetShortLabel {
    param($Asset)
    if ($Asset.Name -and $Asset.Name -ne $Asset.AssetTag) { "$($Asset.Name) ($($Asset.AssetTag))" } else { $Asset.AssetTag }
}

function Test-LooksLikeCaddy {
    param($Asset)
    foreach ($word in @($script:Ctx.Config.CaddyKeywords)) {
        foreach ($text in $Asset.AssetTag, $Asset.Name, $Asset.Model, $Asset.Category) {
            if (Test-ContainsText $text $word) { return $true }
        }
    }
    $false
}

# Plain-English description of where Snipe-IT says an asset is
function Get-AssignedLabel {
    param($Asset)
    switch ($Asset.AssignedType) {
        'asset' {
            $holder = $script:Ctx.Index.ById[$Asset.AssignedId]
            if (-not $holder) { return "asset $($Asset.AssignedName)" }
            $kind = if (Test-LooksLikeCaddy $holder) { 'caddy' } else { 'asset' }
            "$kind $(Get-AssetShortLabel $holder)"
        }
        'user'     { "user $($Asset.AssignedName)" }
        'location' { "location $($Asset.AssignedName)" }
        default    { 'not checked out' }
    }
}

function Format-UserLine {
    param($User)
    $line = $User.Name
    if ($User.Username) { $line += " ($($User.Username))" }
    if ($User.Email -and $User.Email -ne $User.Username) { $line += "  $($User.Email)" }
    $line
}

#endregion

#region Finding who or where something goes ---------------------------------------------------

function Resolve-UserInteractive {
    param([string]$Value)
    while ($true) {
        if (-not $Value) { return $null }
        $key = $Value.Trim()
        if ($script:Ctx.UserCache.ContainsKey($key)) { return $script:Ctx.UserCache[$key] }

        $users = @(Find-SnipeUsers -Search $key)
        $exact = @($users | Where-Object {
            $_.Username -eq $key -or $_.Email -eq $key -or $_.Name -eq $key -or ($_.EmployeeNum -and $_.EmployeeNum -eq $key)
        })

        $pick = $null
        if ($exact.Count -eq 1) { $pick = $exact[0] }
        else {
            $list = if ($exact.Count -gt 1) { $exact } else { @($users | Select-Object -First 10) }
            if ($list.Count -eq 0) {
                Write-Host "  No user matches '$key'." -ForegroundColor Yellow
                $Value = Read-Host '  Type a name, username or email to search again, or press Enter to skip'
                continue
            }
            Write-Host "  Users matching '$key':" -ForegroundColor Yellow
            for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ('   [{0}] {1}' -f ($i + 1), (Format-UserLine $list[$i])) }
            $c = Read-Host '  Type the number, search again with different text, or press Enter to skip'
            if (-not $c) { return $null }
            if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $list.Count) { $pick = $list[[int]$c - 1] }
            else { $Value = $c; continue }
        }

        $short  = if ($pick.Username) { "$($pick.Name) ($($pick.Username))" } else { $pick.Name }
        $target = [pscustomobject]@{ Type = 'user'; Id = $pick.Id; Label = "user $short" }
        $script:Ctx.UserCache[$key] = $target
        return $target
    }
}

function Resolve-LocationInteractive {
    param([string]$Value)
    while ($true) {
        if (-not $Value) { return $null }
        $key = $Value.Trim()
        $exact = @($script:Ctx.Locations | Where-Object { $_.Name -eq $key })
        $list  = if ($exact.Count) { $exact } else { @($script:Ctx.Locations | Where-Object { Test-ContainsText $_.Name $key } | Select-Object -First 10) }

        if ($list.Count -eq 1 -and $exact.Count -eq 1) {
            return [pscustomobject]@{ Type = 'location'; Id = $list[0].Id; Label = "location $($list[0].Name)" }
        }
        if ($list.Count -eq 0) {
            Write-Host "  No location matches '$key'." -ForegroundColor Yellow
            $Value = Read-Host '  Type part of the location name to search again, or press Enter to skip'
            continue
        }
        Write-Host "  Locations matching '$key':" -ForegroundColor Yellow
        for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ('   [{0}] {1}' -f ($i + 1), $list[$i].Name) }
        $c = Read-Host '  Type the number, search again, or press Enter to skip'
        if (-not $c) { return $null }
        if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $list.Count) {
            $l = $list[[int]$c - 1]
            return [pscustomobject]@{ Type = 'location'; Id = $l.Id; Label = "location $($l.Name)" }
        }
        $Value = $c
    }
}

function Resolve-Target {
    param([ValidateSet('user', 'location', 'asset')][string]$Type, [string]$Value)
    switch ($Type) {
        'user'     { Resolve-UserInteractive -Value $Value }
        'location' { Resolve-LocationInteractive -Value $Value }
        'asset' {
            $m = Resolve-AssetInteractive -Index $script:Ctx.Index -Value $Value
            if ($m) {
                $kind = if (Test-LooksLikeCaddy $m.Asset) { 'caddy' } else { 'asset' }
                [pscustomobject]@{ Type = 'asset'; Id = $m.Asset.Id; Label = "$kind $(Get-AssetShortLabel $m.Asset)" }
            }
        }
    }
}

#endregion

#region Doing the change ------------------------------------------------------------------------

# Re-reads an asset from Snipe-IT and refreshes the local copy
function Sync-Asset {
    param([int]$Id)
    $fresh = Get-SnipeAsset -Id $Id
    Update-AssetIndex -Index $script:Ctx.Index -Asset $fresh
    $fresh
}

# One check-in or check-out, with the safety checks every mode needs.
# In practice mode (-WhatIf) it still reads the live asset, so the preview is accurate, but changes nothing.
# Returns @{ Result = Done | WhatIf | Skipped | Failed; Detail }
function Invoke-AssetAction {
    param(
        [Parameter(Mandatory)]$Asset,
        [Parameter(Mandatory)][ValidateSet('Checkout', 'Checkin')][string]$Action,
        $Target,
        [string]$Note,
        $ExpectedCheckin,
        [int]$CheckinLocationId,
        [switch]$Transfer
    )
    $out = { param($r, $d, $b) [pscustomobject]@{ Result = $r; Detail = $d; Before = $b } }
    $fullNote = ("$Note" + " [via Snipe tool by $($script:Ctx.RunBy)]").Trim()

    try {
        # Always act on the current state in Snipe-IT, not the copy loaded at the start
        $live = Get-SnipeAsset -Id $Asset.Id
        if ($Action -eq 'Checkin') {
            if (-not $live.AssignedType) { return & $out 'Skipped' 'Already checked in' }
            if ($WhatIfPreference) { return & $out 'WhatIf' "Would check in from $(Get-AssignedLabel $live)" }
            Invoke-SnipeCheckin -AssetId $live.Id -Note $fullNote -LocationId $CheckinLocationId
        }
        else {
            if ($live.AssignedType -eq $Target.Type -and $live.AssignedId -eq $Target.Id) {
                return & $out 'Skipped' "Already checked out to $($Target.Label)"
            }
            if ($live.StatusType -and $live.StatusType -ne 'deployable') {
                return & $out 'Failed' "Status is '$($live.Status)' - it can't be checked out"
            }
            if ($live.AssignedType -and -not $Transfer) { return & $out 'Skipped' "Checked out to $(Get-AssignedLabel $live)" }
            if ($WhatIfPreference) {
                $from = if ($live.AssignedType) { " (transferring from $(Get-AssignedLabel $live))" } else { '' }
                return & $out 'WhatIf' "Would check out to $($Target.Label)$from"
            }
            if ($live.AssignedType) {
                Invoke-SnipeCheckin -AssetId $live.Id -Note "Transferred to $($Target.Label). $fullNote"
            }
            Invoke-SnipeCheckout -AssetId $live.Id -TargetType $Target.Type -TargetId $Target.Id -Note $fullNote -ExpectedCheckin $ExpectedCheckin
        }
        [void](Sync-Asset -Id $live.Id)
        Add-UndoEntry -Asset $live -Label $(if ($Action -eq 'Checkout') { "check out to $($Target.Label)" } else { 'check in' })
        & $out 'Done' '' $live
    }
    catch { & $out 'Failed' $_.Exception.Message }
}

#endregion

#region Undo ------------------------------------------------------------------------------------

# Every successful change remembers what the asset looked like before, so it can be put back.
function Add-UndoEntry {
    param($Asset, [string]$Label)
    $script:Ctx.History.Add([pscustomobject]@{ AssetId = $Asset.Id; AssetTag = $Asset.AssetTag; Label = $Label; Before = $Asset })
}

function Get-StateText {
    param($Snapshot)
    "$(Get-AssignedLabel $Snapshot), status '$($Snapshot.Status)'"
}

# Puts an asset back how it was: check in, restore the status, then check back out to the previous holder
function Undo-AssetChange {
    param([Parameter(Mandatory)]$Entry)
    $out = { param($r, $d) [pscustomobject]@{ Result = $r; Detail = $d } }
    $b = $Entry.Before
    if ($WhatIfPreference) { return & $out 'WhatIf' "Would put back to: $(Get-StateText $b)" }
    try {
        $live = Get-SnipeAsset -Id $Entry.AssetId
        $note = "Undo of: $($Entry.Label) [via Snipe tool by $($script:Ctx.RunBy)]"
        if ($live.AssignedType) { Invoke-SnipeCheckin -AssetId $live.Id -Note $note }
        if ($b.StatusId -and $b.StatusId -ne $live.StatusId) { Set-SnipeAssetStatus -AssetId $live.Id -StatusId $b.StatusId }
        $detail = ''
        if ($b.AssignedType -in 'user', 'location', 'asset') {
            $due = $null
            if ($b.ExpectedCheckin) {
                if (([datetime]$b.ExpectedCheckin).Date -ge (Get-Date).Date) { $due = $b.ExpectedCheckin }
                else { $detail = 'its old return date was in the past, so no return date was set' }
            }
            Invoke-SnipeCheckout -AssetId $live.Id -TargetType $b.AssignedType -TargetId $b.AssignedId -Note $note -ExpectedCheckin $due
        }
        [void](Sync-Asset -Id $live.Id)
        & $out 'Done' $detail
    }
    catch { & $out 'Failed' $_.Exception.Message }
}

# Undoes the most recent change after confirming. Used by typing UNDO at any scan prompt.
function Invoke-UndoLast {
    if ($script:Ctx.History.Count -eq 0) { Write-Host '  Nothing to undo.' -ForegroundColor DarkYellow; return }
    $entry = $script:Ctx.History[$script:Ctx.History.Count - 1]
    $current = $script:Ctx.Index.ById[$entry.AssetId]
    Write-Host "  Last change: $($entry.AssetTag) - $($entry.Label)" -ForegroundColor Cyan
    if ($current) { Write-Host "  Now:         $(Get-StateText $current)" }
    Write-Host "  Put back to: $(Get-StateText $entry.Before)"
    if (-not (Read-YesNo '  Undo it?')) { return }
    $outcome = Undo-AssetChange -Entry $entry
    Write-ActionLine -Tag $entry.AssetTag -Outcome $outcome -Extra '- undo'
    if ($outcome.Result -eq 'Done') { $script:Ctx.History.RemoveAt($script:Ctx.History.Count - 1) }
}

function Test-UndoCommand {
    param([string]$Text)
    "$Text".Trim() -eq 'undo'
}

#endregion

#region Audit -----------------------------------------------------------------------------------

# Records assets as audited in Snipe-IT. If this Snipe-IT version doesn't support it, says so once and stops trying.
function Invoke-AuditRecord {
    param([Parameter(Mandatory)]$Asset, [string]$Note)
    if ($script:Ctx.AuditUnsupported) { return 'Not supported' }
    if ($WhatIfPreference) { return 'WhatIf' }
    try {
        Invoke-SnipeAudit -AssetTag $Asset.AssetTag -Note ("$Note [via Snipe tool by $($script:Ctx.RunBy)]").Trim()
        'Yes'
    }
    catch {
        if ($_.Exception.Message -match '404|405|Not Found|Method Not Allowed') {
            $script:Ctx.AuditUnsupported = $true
            Write-Host '  This Snipe-IT version does not support recording audits through the API - skipping audits.' -ForegroundColor DarkYellow
            return 'Not supported'
        }
        "Failed: $($_.Exception.Message)"
    }
}

function Write-ActionLine {
    param([string]$Tag, $Outcome, [string]$Extra)
    $colour = @{ Done = 'Green'; WhatIf = 'Magenta'; Skipped = 'DarkYellow'; Failed = 'Red' }[$Outcome.Result]
    $label  = @{ Done = 'DONE'; WhatIf = 'WHATIF'; Skipped = 'SKIPPED'; Failed = 'FAILED' }[$Outcome.Result]
    $text = "  [$label] $Tag"
    if ($Extra) { $text += " $Extra" }
    if ($Outcome.Detail) { $text += " - $($Outcome.Detail)" }
    Write-Host $text -ForegroundColor $colour
}

#endregion

#region Reports -------------------------------------------------------------------------------

function Save-Report {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Rows)
    $dir = Join-Path $script:Ctx.Root 'reports'
    New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    $path = Join-Path $dir ('{0}_{1:yyyyMMdd_HHmmss}.csv' -f $Name, (Get-Date))
    @($Rows) | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    $path
}

function Write-Summary {
    param($Rows, [string]$Property = 'Result')
    @($Rows) | Group-Object $Property | Sort-Object Name | ForEach-Object { Write-Host ('  {0,-12} {1}' -f $_.Name, $_.Count) }
}

#endregion
