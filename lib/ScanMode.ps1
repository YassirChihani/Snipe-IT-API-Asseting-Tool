# Scan modes: set up who or where once, then scan asset after asset.

function New-ScanRow {
    param([string]$Mode, [string]$Scanned, $Asset, [string]$Field, [string]$Target, [string]$Before, $Expected, [string]$Note, $Outcome)
    [pscustomobject]@{
        Time            = (Get-Date).ToString('HH:mm:ss')
        Mode            = $Mode
        Scanned         = $Scanned
        AssetTag        = if ($Asset) { $Asset.AssetTag } else { '' }
        Serial          = if ($Asset) { $Asset.Serial } else { '' }
        Model           = if ($Asset) { $Asset.Model } else { '' }
        MatchedField    = $Field
        Target          = $Target
        WasAssignedTo   = $Before
        ExpectedCheckin = Format-Date $Expected
        Note            = $Note
        Result          = if ($Outcome) { $Outcome.Result } else { 'Failed' }
        Detail          = if ($Outcome) { $Outcome.Detail } else { 'Not found in Snipe-IT' }
    }
}

function Invoke-ScanCheckout {
    Write-Header 'Check out (scan)'

    $typeKey = Read-Choice 'Check out to [U]ser, [L]ocation or [A]sset (e.g. a caddy)? [B] to go back' @('U', 'L', 'A', 'B')
    if ($typeKey -eq 'B') { return }
    $type = @{ U = 'user'; L = 'location'; A = 'asset' }[$typeKey]
    $target = $null
    while (-not $target) {
        $v = Read-Host "$((Get-Culture).TextInfo.ToTitleCase($type)) [Enter=back]"
        if (-not $v) { return }
        $target = Resolve-Target -Type $type -Value $v
    }
    Write-Host "  Target: $($target.Label)" -ForegroundColor Green

    $expected = Read-DateInput 'Expected return date (dd/MM/yyyy, +days, or Enter for none)'
    $note     = Read-Host 'Note for every check-out this session (or Enter for none)'
    $policy   = Read-Choice 'If an asset is already checked out elsewhere: [A]sk each time, [T]ransfer it, [S]kip it (Enter = Ask)' @('A', 'T', 'S') 'A'

    Write-Host "`nChecking out to $($target.Label). UNDO = undo last | Enter = finish" -ForegroundColor Cyan
    $rows = [System.Collections.Generic.List[object]]::new()
    $done = 0
    while ($true) {
        $scan = Read-Host "  Asset ($done checked out)"
        if (-not $scan) { break }
        if (Test-UndoCommand $scan) { Invoke-UndoLast; continue }

        $m = Resolve-AssetInteractive -Index $script:Ctx.Index -Value $scan
        if (-not $m) {
            $rows.Add((New-ScanRow -Mode 'Checkout' -Scanned $scan -Target $target.Label))
            Write-Host "  [UNKNOWN] $scan - not found, recorded in the report" -ForegroundColor Red
            continue
        }
        $a = $m.Asset
        if ($target.Type -eq 'asset' -and $a.Id -eq $target.Id) { Write-Host '  That is the target itself - skipped.' -ForegroundColor DarkGray; continue }

        $before = Get-AssignedLabel $a
        if ($a.StatusType -and $a.StatusType -ne 'deployable') {
            $outcome = [pscustomobject]@{ Result = 'Failed'; Detail = "Status is '$($a.Status)' - it can't be checked out" }
            Write-ActionLine -Tag $a.AssetTag -Outcome $outcome
            $rows.Add((New-ScanRow -Mode 'Checkout' -Scanned $scan -Asset $a -Field $m.Field -Target $target.Label -Before $before -Outcome $outcome))
            continue
        }
        $transfer = $false
        $alreadyThere = $a.AssignedType -eq $target.Type -and $a.AssignedId -eq $target.Id
        if ($a.AssignedType -and -not $alreadyThere) {
            $transfer = switch ($policy) {
                'T' { $true }
                'S' { $false }
                'A' { Read-YesNo "  $($a.AssetTag) is checked out to $before. Transfer it to $($target.Label)?" }
            }
        }

        $outcome = Invoke-AssetAction -Asset $a -Action Checkout -Target $target -Note $note -ExpectedCheckin $expected -Transfer:$transfer
        if ($outcome.Result -in 'Done', 'WhatIf') { $done++ }
        $via = if ($m.Field -ne 'Asset tag') { "(found via $($m.Field))" } else { '' }
        Write-ActionLine -Tag $a.AssetTag -Outcome $outcome -Extra $via
        $rows.Add((New-ScanRow -Mode 'Checkout' -Scanned $scan -Asset $a -Field $m.Field -Target $target.Label -Before $before -Expected $expected -Note $note -Outcome $outcome))
    }

    if ($rows.Count) {
        Write-Host "`nSession summary:" -ForegroundColor Cyan
        Write-Summary $rows
        Write-Host "Report: $(Save-Report -Name 'checkout' -Rows $rows)"
    }
}

function Invoke-ScanCheckin {
    Write-Header 'Check in (scan)'

    $note = Read-Host 'Note for every check-in this session, e.g. "Returned, charger missing" (or Enter for none)'
    $locationId = 0
    $loc = Read-Host 'Location [Enter=asset default]'
    if ($loc) {
        $l = Resolve-LocationInteractive -Value $loc
        if ($l) { $locationId = $l.Id; Write-Host "  Location: $($l.Label)" -ForegroundColor Green }
    }

    Write-Host "`nUNDO = undo last | Enter = finish" -ForegroundColor Cyan
    $rows = [System.Collections.Generic.List[object]]::new()
    $done = 0
    $today = (Get-Date).Date
    while ($true) {
        $scan = Read-Host "  Asset ($done checked in)"
        if (-not $scan) { break }
        if (Test-UndoCommand $scan) { Invoke-UndoLast; continue }

        $m = Resolve-AssetInteractive -Index $script:Ctx.Index -Value $scan
        if (-not $m) {
            $rows.Add((New-ScanRow -Mode 'Checkin' -Scanned $scan))
            Write-Host "  [UNKNOWN] $scan - not found, recorded in the report" -ForegroundColor Red
            continue
        }
        $a = $m.Asset
        $before = Get-AssignedLabel $a
        $late = ''
        if ($a.AssignedType -and $a.ExpectedCheckin -and ([datetime]$a.ExpectedCheckin).Date -lt $today) {
            $late = "(returned $(($today - ([datetime]$a.ExpectedCheckin).Date).Days) day(s) late)"
        }

        $outcome = Invoke-AssetAction -Asset $a -Action Checkin -Note $note -CheckinLocationId $locationId
        if ($outcome.Result -in 'Done', 'WhatIf') { $done++ }
        $extra = (@("from $before", $late) | Where-Object { $_ }) -join ' '
        if ($outcome.Result -eq 'Skipped') { $extra = '' }
        Write-ActionLine -Tag $a.AssetTag -Outcome $outcome -Extra $extra
        $row = New-ScanRow -Mode 'Checkin' -Scanned $scan -Asset $a -Field $m.Field -Before $before -Note $note -Outcome $outcome
        if ($late) { $row.Detail = ("$($row.Detail) $late").Trim() }
        $rows.Add($row)
    }

    if ($rows.Count) {
        Write-Host "`nSession summary:" -ForegroundColor Cyan
        Write-Summary $rows
        Write-Host "Report: $(Save-Report -Name 'checkin' -Rows $rows)"
    }
}
