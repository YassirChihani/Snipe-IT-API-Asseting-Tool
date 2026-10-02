# "Scan an asset" mode: scan any asset, see where it is and its status, then choose what to do.
# After the first action, [R] repeats it on the next asset, so a run of the same job is one key per scan.

function Show-AssetCard {
    param($Asset, [string]$Field)
    $today = (Get-Date).Date
    Write-Host ''
    Write-Host "  $(Format-AssetLine $Asset)" -ForegroundColor White
    $deployed = if ($Asset.AssignedType -and $Asset.StatusType -eq 'deployable') { ' (deployed)' } else { '' }
    Write-Host "  Status:      $($Asset.Status)$deployed"
    Write-Host "  Assigned to: $(Get-AssignedLabel $Asset)"
    if ($Asset.AssignedType -and $Asset.ExpectedCheckin) {
        $due = ([datetime]$Asset.ExpectedCheckin).Date
        $late = if ($due -lt $today) { "  OVERDUE by $(($today - $due).Days) day(s)" } else { '' }
        Write-Host "  Due back:    $(Format-Date $due)$late" -ForegroundColor $(if ($late) { 'Red' } else { 'Gray' })
    }
    if ($Field -and $Field -ne 'Asset tag') { Write-Host "  (found via $Field)" -ForegroundColor DarkGray }
}

function Select-StatusLabel {
    param([string]$Prompt = 'Choose a status')
    $list = @($script:Ctx.Statuses)
    if ($list.Count -eq 0) { Write-Host '  No status labels found in Snipe-IT.' -ForegroundColor Red; return $null }
    for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ('   [{0}] {1}  ({2})' -f ($i + 1), $list[$i].Name, $list[$i].Type) }
    $c = Read-Host "  $Prompt - type the number, or press Enter to cancel"
    if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $list.Count) { return $list[[int]$c - 1] }
    $null
}

# Changes an asset's status. Statuses that mean "not usable" (undeployable / archived) can't stay
# checked out, so the asset is checked in first.
function Set-AssetStatusSafely {
    param($Asset, $Status, [string]$Note)
    $out = { param($r, $d) [pscustomobject]@{ Result = $r; Detail = $d } }
    try {
        $live = Get-SnipeAsset -Id $Asset.Id
        if ($live.Status -eq $Status.Name) { return & $out 'Skipped' "Already '$($Status.Name)'" }
        $needsCheckin = $live.AssignedType -and $Status.Type -in 'undeployable', 'archived'

        if ($WhatIfPreference) {
            $pre = if ($needsCheckin) { "check in from $(Get-AssignedLabel $live), then " } else { '' }
            return & $out 'WhatIf' "Would $($pre)mark as '$($Status.Name)'"
        }
        if ($needsCheckin) {
            Invoke-SnipeCheckin -AssetId $live.Id -Note ("Marked as $($Status.Name). $Note [via Snipe tool by $($script:Ctx.RunBy)]").Trim()
        }
        Set-SnipeAssetStatus -AssetId $live.Id -StatusId $Status.Id
        [void](Sync-Asset -Id $live.Id)
        Add-UndoEntry -Asset $live -Label "mark as '$($Status.Name)'"
        $d = if ($needsCheckin) { 'checked in first' } else { '' }
        & $out 'Done' $d
    }
    catch { & $out 'Failed' $_.Exception.Message }
}

# Asks who/where to check out to. Returns the target, or $null if cancelled.
function Read-CheckoutTarget {
    $typeKey = Read-Choice '  Target: [U]ser [L]ocation [A]sset [B]ack' @('U', 'L', 'A', 'B')
    if ($typeKey -eq 'B') { return $null }
    $type = @{ U = 'user'; L = 'location'; A = 'asset' }[$typeKey]
    $v = Read-Host "  Scan or type the $type, or press Enter to cancel"
    if (-not $v) { return $null }
    Resolve-Target -Type $type -Value $v
}

function Invoke-AssetDesk {
    Write-Header 'Scan an asset'
    Write-Host 'Scan an asset to see its details and choose what to do.'
    Write-Host 'Type UNDO to undo the last change. Press Enter on an empty line to return to the main menu.'

    $rows = [System.Collections.Generic.List[object]]::new()
    $last = $null   # the last action, so [R] can repeat it

    while ($true) {
        $scan = Read-Host "`nScan an asset"
        if (-not $scan) { break }
        if (Test-UndoCommand $scan) { Invoke-UndoLast; continue }
        $m = Resolve-AssetInteractive -Index $script:Ctx.Index -Value $scan
        if (-not $m) { continue }
        $a = $m.Asset
        Show-AssetCard -Asset $a -Field $m.Field

        # --- Build the menu for this asset ---
        $valid = [System.Collections.Generic.List[string]]::new()
        Write-Host ''
        if ($last) { Write-Host "  [R] Repeat: $($last.Label)" -ForegroundColor Cyan; $valid.Add('R') }
        if ($a.AssignedType) {
            Write-Host '  [I] Check in'
            Write-Host '  [O] Check out to someone or somewhere else (transfer)'
            $valid.Add('I')
        }
        else { Write-Host '  [O] Check out' }
        Write-Host '  [S] Change status (mark as...)'
        Write-Host '  [A] Record audit (confirm it was physically seen today)'
        Write-Host '  [Enter] Next asset'
        $valid.Add('O'); $valid.Add('S'); $valid.Add('A')
        $choice = Read-Choice '  Action' $valid 'X'
        if ($choice -eq 'X') { continue }

        # --- Work out the action ---
        $action = $null
        if ($choice -eq 'R') { $action = $last }
        elseif ($choice -eq 'O') {
            $t = Read-CheckoutTarget
            if (-not $t) { continue }
            $due  = Read-DateInput '  Expected return date (dd/MM/yyyy, +days, or Enter for none)'
            $note = Read-Host '  Note [Enter=none]'
            $action = @{ Kind = 'Checkout'; Target = $t; Due = $due; Note = $note; Label = "check out to $($t.Label)" }
        }
        elseif ($choice -eq 'I') {
            $note = Read-Host '  Note [Enter=none]'
            $loc = $null
            $locText = Read-Host '  Location [Enter=default]'
            if ($locText) { $loc = Resolve-LocationInteractive -Value $locText }
            $status = $null
            if (Read-YesNo '  Change status?') { $status = Select-StatusLabel 'Status after check-in' }
            $label = 'check in'
            if ($loc) { $label += " to $($loc.Label)" }
            if ($status) { $label += " and mark as '$($status.Name)'" }
            $action = @{ Kind = 'Checkin'; Note = $note; Status = $status; LocationId = $(if ($loc) { $loc.Id } else { 0 }); Label = $label }
        }
        elseif ($choice -eq 'S') {
            $status = Select-StatusLabel 'New status'
            if (-not $status) { continue }
            if ($a.AssignedType -and $status.Type -in 'undeployable', 'archived') {
                if (-not (Read-YesNo "  '$($status.Name)' assets can't stay checked out, so it will be checked in from $(Get-AssignedLabel $a) first. OK?")) { continue }
            }
            $note = Read-Host '  Note [Enter=none]'
            $action = @{ Kind = 'Status'; Status = $status; Note = $note; Label = "mark as '$($status.Name)'" }
        }
        elseif ($choice -eq 'A') {
            $note = Read-Host '  Audit note (or Enter for none)'
            $action = @{ Kind = 'Audit'; Note = $note; Label = 'record audit' }
        }

        # --- Do it ---
        $before = Get-AssignedLabel $a
        $beforeStatus = $a.Status
        switch ($action.Kind) {
            'Checkout' {
                $transfer = $false
                $already = $a.AssignedType -eq $action.Target.Type -and $a.AssignedId -eq $action.Target.Id
                if ($a.AssignedType -and -not $already) {
                    $transfer = ($choice -eq 'O') -or (Read-YesNo "  It's checked out to $before. Transfer it?")
                }
                $outcome = Invoke-AssetAction -Asset $a -Action Checkout -Target $action.Target -Note $action.Note -ExpectedCheckin $action.Due -Transfer:$transfer
            }
            'Checkin' {
                $outcome = Invoke-AssetAction -Asset $a -Action Checkin -Note $action.Note -CheckinLocationId $action.LocationId
                if ($action.Status -and $outcome.Result -in 'Done', 'WhatIf', 'Skipped') {
                    $s = Set-AssetStatusSafely -Asset $a -Status $action.Status -Note $action.Note
                    if ($s.Result -eq 'Failed') { $outcome = $s }
                    elseif ($outcome.Result -eq 'Skipped' -and $s.Result -ne 'Skipped') { $outcome = $s }
                }
            }
            'Status' { $outcome = Set-AssetStatusSafely -Asset $a -Status $action.Status -Note $action.Note }
            'Audit' {
                $r = Invoke-AuditRecord -Asset $a -Note $action.Note
                $outcome = switch -Wildcard ($r) {
                    'Yes'    { [pscustomobject]@{ Result = 'Done'; Detail = '' } }
                    'WhatIf' { [pscustomobject]@{ Result = 'WhatIf'; Detail = 'Would record an audit' } }
                    default  { [pscustomobject]@{ Result = 'Failed'; Detail = $r } }
                }
            }
        }

        Write-ActionLine -Tag $a.AssetTag -Outcome $outcome -Extra "- $($action.Label)"
        $rows.Add([pscustomobject]@{
            Time          = (Get-Date).ToString('HH:mm:ss')
            Scanned       = $scan
            AssetTag      = $a.AssetTag
            Model         = $a.Model
            Action        = $action.Label
            WasAssignedTo = $before
            StatusBefore  = $beforeStatus
            Note          = $action.Note
            Result        = $outcome.Result
            Detail        = $outcome.Detail
        })
        if ($outcome.Result -ne 'Failed') { $last = $action }
    }

    if ($rows.Count) {
        Write-Host "`nSession summary:" -ForegroundColor Cyan
        Write-Summary $rows
        Write-Host "Report: $(Save-Report -Name 'scan-desk' -Rows $rows)"
    }
}
