# Caddy audit: scan a caddy, scan the laptops physically in it, compare with Snipe-IT,
# then update Snipe-IT or produce a physical move list.

function New-Result {
    param($Caddy, [string]$Scanned, $Asset, [string]$Field, [string]$Result, [string]$Detail)
    [pscustomobject]@{
        Time         = (Get-Date).ToString('HH:mm:ss')
        Caddy        = if ($Caddy) { Get-AssetShortLabel $Caddy } else { '' }
        Scanned      = $Scanned
        AssetTag     = if ($Asset) { $Asset.AssetTag } else { '' }
        Serial       = if ($Asset) { $Asset.Serial } else { '' }
        Model        = if ($Asset) { $Asset.Model } else { '' }
        MatchedField = $Field
        Result       = $Result
        SnipeSaid    = if ($Asset) { Get-AssignedLabel $Asset } else { '' }
        Detail       = $Detail
        Audited      = ''
        Action       = ''
        ActionResult = ''
        AssetId      = if ($Asset) { $Asset.Id } else { $null }
    }
}

# Records the laptop in this caddy in Snipe-IT: check in from wherever it is, then check out to the caddy
function Move-LaptopToCaddy {
    param($Result, $Caddy)
    $caddyLabel = Get-AssetShortLabel $Caddy
    $Result.Action = "Update Snipe-IT: record in $caddyLabel"

    if ($WhatIfPreference) {
        Write-Host "   WHATIF: would record $($Result.AssetTag) in $caddyLabel" -ForegroundColor Magenta
        $Result.ActionResult = 'WhatIf'
        return
    }
    try {
        # Re-read the asset first in case someone changed it since the session started
        $live = Get-SnipeAsset -Id $Result.AssetId
        $note = "Caddy audit $($script:Ctx.Today) by $($script:Ctx.RunBy): found physically in $caddyLabel (Snipe-IT said $(Get-AssignedLabel $live))"
        if ($live.AssignedType) { Invoke-SnipeCheckin -AssetId $live.Id -Note $note }
        Invoke-SnipeCheckout -AssetId $live.Id -TargetType asset -TargetId $Caddy.Id -Note $note

        [void](Sync-Asset -Id $live.Id)
        Add-UndoEntry -Asset $live -Label "record in $caddyLabel (caddy audit)"
        $Result.ActionResult = 'Done'
        Write-Host "   [DONE] $($Result.AssetTag) now recorded in $caddyLabel" -ForegroundColor Green
    }
    catch {
        $Result.ActionResult = "Failed: $($_.Exception.Message)"
        Write-Host "   [FAILED] $($Result.AssetTag): $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Add-ToMoveList {
    param($Result)
    $Result.Action = switch ($Result.Result) {
        'Wrong caddy' { "Physically move to $($Result.SnipeSaid -replace '^caddy ', '')" }
        'Loaned'      { "Check: Snipe-IT says it's with $($Result.SnipeSaid) - has it been returned?" }
        'Unassigned'  { 'Decide which caddy it belongs to' }
    }
    $Result.ActionResult = 'Move list'
}

function Invoke-CaddyAudit {
    Write-Header 'Caddy audit'
    $results   = [System.Collections.Generic.List[object]]::new()   # everything that happened this session
    $audited   = @{}                                                 # caddy id -> caddy asset
    $scannedIn = @{}                                                 # laptop id -> label of caddy it was found in
    $recordAudits = Read-YesNo 'Also record every laptop you scan as audited in Snipe-IT (updates its last audit date)?'

    while ($true) {
        $caddyScan = Read-Host "`nScan a CADDY (or press Enter to finish the session)"
        if (-not $caddyScan) { break }

        $caddyMatch = Resolve-AssetInteractive -Index $script:Ctx.Index -Value $caddyScan
        if (-not $caddyMatch) { continue }
        $caddy = $caddyMatch.Asset

        if (-not (Test-LooksLikeCaddy $caddy)) {
            $ok = Read-Host "  $(Format-AssetLine $caddy) doesn't look like a caddy. Use it anyway? (y/n)"
            if ($ok -ne 'y') { continue }
        }
        if ($audited.ContainsKey($caddy.Id)) {
            Write-Host '  This caddy was already audited this session - auditing it again.' -ForegroundColor Yellow
        }
        $audited[$caddy.Id] = $caddy

        $expected = @($script:Ctx.Index.ById.Values | Where-Object { $_.AssignedType -eq 'asset' -and $_.AssignedId -eq $caddy.Id })
        $where = if ($caddy.AssignedName) { " at $($caddy.AssignedName)" } else { '' }
        Write-Host "`nCaddy $(Get-AssetShortLabel $caddy)$where - Snipe-IT lists $($expected.Count) laptop(s) in it." -ForegroundColor Cyan
        Write-Host 'Scan each laptop in the caddy. Press Enter on an empty line when done.'

        # --- Scan laptops ---
        $caddyResults = [System.Collections.Generic.List[object]]::new()
        $seen = @{}
        while ($true) {
            $scan = Read-Host "  Laptop ($($seen.Count) scanned)"
            if (-not $scan) { break }

            $m = Resolve-AssetInteractive -Index $script:Ctx.Index -Value $scan
            if (-not $m) {
                $r = New-Result -Caddy $caddy -Scanned $scan -Result 'Unknown' -Detail 'Not found in Snipe-IT'
                $caddyResults.Add($r)
                Write-Host "  [UNKNOWN] $scan - recorded for follow-up" -ForegroundColor Red
                continue
            }
            $a = $m.Asset
            if ($a.Id -eq $caddy.Id)   { Write-Host '  That is the caddy itself - skipped.' -ForegroundColor DarkGray; continue }
            if ($seen.ContainsKey($a.Id)) { Write-Host "  $($a.AssetTag) already scanned - skipped." -ForegroundColor DarkGray; continue }
            $seen[$a.Id] = $true
            $scannedIn[$a.Id] = Get-AssetShortLabel $caddy

            $via = if ($m.Field -ne 'Asset tag') { " (found via $($m.Field))" } else { '' }
            $notDeployable = $a.StatusType -and $a.StatusType -ne 'deployable'
            $detail = if ($notDeployable) { "Status is '$($a.Status)'" } else { '' }

            if ($a.AssignedType -eq 'asset' -and $a.AssignedId -eq $caddy.Id) {
                $result = 'OK'; $colour = 'Green'; $msg = 'correct caddy'
            }
            elseif ($a.AssignedType -eq 'asset') {
                $result = 'Wrong caddy'; $colour = 'Yellow'; $msg = "Snipe-IT says $(Get-AssignedLabel $a)"
            }
            elseif ($a.AssignedType) {
                $result = 'Loaned'; $colour = 'Yellow'; $msg = "Snipe-IT says checked out to $(Get-AssignedLabel $a)"
            }
            else {
                $result = 'Unassigned'; $colour = 'Yellow'; $msg = 'not checked out to any caddy'
            }
            if ($notDeployable) { $msg += " - WARNING: status is '$($a.Status)'"; $colour = 'Red' }

            $caddyResults.Add((New-Result -Caddy $caddy -Scanned $scan -Asset $a -Field $m.Field -Result $result -Detail $detail))
            Write-Host ("  [{0}] {1}{2} - {3}" -f $result.ToUpper(), $a.AssetTag, $via, $msg) -ForegroundColor $colour
        }

        # --- Laptops Snipe-IT expected but weren't scanned ---
        foreach ($e in $expected | Where-Object { -not $seen.ContainsKey($_.Id) }) {
            $caddyResults.Add((New-Result -Caddy $caddy -Asset $e -Result 'Missing' -Detail 'Recorded in this caddy but not scanned'))
        }

        # --- Record audits for everything physically seen ---
    if ($recordAudits) {
        $seenRows = @($caddyResults | Where-Object { $_.AssetId -and $_.Result -notin 'Missing', 'Unknown' })
        $note = "Seen in $(Get-AssetShortLabel $caddy) during caddy audit"
        [void](Invoke-AuditRecord -Asset $caddy -Note 'Caddy audited')
        foreach ($r in $seenRows) { $r.Audited = Invoke-AuditRecord -Asset $script:Ctx.Index.ById[$r.AssetId] -Note $note }
        $ok = @($seenRows | Where-Object Audited -eq 'Yes').Count
        if ($ok) { Write-Host "  Recorded $ok audit(s) in Snipe-IT." -ForegroundColor Green }
        elseif ($WhatIfPreference -and $seenRows.Count) { Write-Host "  WHATIF: would record $($seenRows.Count) audit(s)." -ForegroundColor Magenta }
    }

    # --- Summary for this caddy ---
        Write-Host "`nSummary for $(Get-AssetShortLabel $caddy):" -ForegroundColor Cyan
        $caddyResults | Group-Object Result | ForEach-Object { Write-Host ('  {0,-12} {1}' -f $_.Name, $_.Count) }
        foreach ($r in $caddyResults | Where-Object Result -eq 'Missing') {
            if ($scannedIn.ContainsKey($r.AssetId)) {
                Write-Host "  [MISSING] $($r.AssetTag) - expected here, but already found in $($scannedIn[$r.AssetId]) this session" -ForegroundColor DarkYellow
            }
            else {
                Write-Host "  [MISSING] $($r.AssetTag) $($r.Model) - expected here but not scanned" -ForegroundColor Red
            }
        }

        # --- Fix mismatches ---
        $fixable = @($caddyResults | Where-Object { $_.Result -in 'Wrong caddy', 'Unassigned', 'Loaned' -and -not $_.Detail })
        $blocked = @($caddyResults | Where-Object { $_.Result -in 'Wrong caddy', 'Unassigned', 'Loaned' -and $_.Detail })
        foreach ($b in $blocked) {
            $b.Action = 'None - check status first'
            Write-Host "  $($b.AssetTag) not changed: $($b.Detail)" -ForegroundColor DarkYellow
        }

        if ($fixable.Count) {
            Write-Host "`n$($fixable.Count) laptop(s) here don't match Snipe-IT. What would you like to do?"
            Write-Host '  [U] Update Snipe-IT so they are recorded in this caddy'
            Write-Host '  [C] Choose one by one'
            Write-Host '  [M] Leave Snipe-IT alone and add them to the physical move list'
            Write-Host '  [S] Skip for now'
            $choice = (Read-Host '  Choice').ToUpper()

            foreach ($r in $fixable) {
                switch ($choice) {
                    'U' {
                        # Loaned laptops are only moved after an explicit yes, because this also ends the loan
                        if ($r.Result -eq 'Loaned') {
                            $yes = Read-Host "  $($r.AssetTag) is checked out to $($r.SnipeSaid). Check it in and record it in this caddy? (y/n)"
                            if ($yes -eq 'y') { Move-LaptopToCaddy $r $caddy } else { Add-ToMoveList $r }
                        }
                        else { Move-LaptopToCaddy $r $caddy }
                    }
                    'C' {
                        $yes = Read-Host "  $($r.AssetTag) ($($r.Result): $($r.SnipeSaid)) - record it in this caddy? (y = update Snipe-IT / n = move list)"
                        if ($yes -eq 'y') { Move-LaptopToCaddy $r $caddy } else { Add-ToMoveList $r }
                    }
                    'M'     { Add-ToMoveList $r }
                    default { $r.Action = 'Skipped' }
                }
            }
        }
        elseif (-not ($caddyResults | Where-Object Result -ne 'OK')) {
            Write-Host '  Everything matches. ' -ForegroundColor Green
        }

        foreach ($r in $caddyResults) { $results.Add($r) }
    }



    if ($results.Count -eq 0) { Write-Host 'Nothing scanned - no report saved.'; return }

    # A laptop "missing" from one caddy may have turned up in another during the session
    foreach ($r in $results | Where-Object Result -eq 'Missing') {
        if ($r.AssetId -and $scannedIn.ContainsKey($r.AssetId)) {
            $r.Detail = "Found in $($scannedIn[$r.AssetId]) during this session"
        }
        else {
            $r.Detail = 'Not found in any caddy audited this session - on loan, in repair or lost?'
        }
    }

    $reportPath = Save-Report -Name 'caddy-audit' -Rows ($results | Select-Object * -ExcludeProperty AssetId)

    $moves = @($results | Where-Object ActionResult -eq 'Move list')
    if ($moves.Count) {
        $movePath = Save-Report -Name 'move-list' -Rows ($moves | Select-Object AssetTag, Serial, Model, @{ n = 'CurrentlyIn'; e = { $_.Caddy } }, SnipeSaid, Action)
    }

    Write-Host "`n=== Session summary ===" -ForegroundColor Cyan
    Write-Host "Caddies audited: $($audited.Count)"
    $results | Group-Object Result | Sort-Object Name | ForEach-Object { Write-Host ('  {0,-12} {1}' -f $_.Name, $_.Count) }
    $lost = @($results | Where-Object { $_.Result -eq 'Missing' -and $_.Detail -like 'Not found*' })
    if ($lost.Count) {
        Write-Host "`nNot found anywhere this session:" -ForegroundColor Red
        $lost | ForEach-Object { Write-Host "  $($_.AssetTag)  $($_.Model)  (should be in $($_.Caddy))" }
    }
    $viaOther = @($results | Where-Object { $_.MatchedField -and $_.MatchedField -ne 'Asset tag' })
    if ($viaOther.Count) {
        Write-Host "`n$($viaOther.Count) laptop(s) were only found by serial or another field - worth checking their labels and Snipe-IT records." -ForegroundColor DarkYellow
    }
    Write-Host "`nReport:    $reportPath"
    if ($moves.Count) { Write-Host "Move list: $movePath" }
}
