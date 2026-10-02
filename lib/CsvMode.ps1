# CSV mode: bulk check-in and check-out, with a different person, location or caddy per row.
# The whole file is validated first, and nothing changes until you confirm.

function ConvertTo-ActionName {
    param([string]$Text)
    switch -Regex ("$Text".Trim()) {
        '^(check ?out|out|loan|issue)$'     { return 'Checkout' }
        '^(check ?in|in|return|returned)$'  { return 'Checkin' }
        default { return $null }
    }
}

function ConvertTo-TargetType {
    param([string]$Text)
    switch -Regex ("$Text".Trim()) {
        '^$'                        { return $null }
        '^(user|person|student|staff)$' { return 'user' }
        '^(location|room|site)$'    { return 'location' }
        '^(asset|caddy|trolley)$'   { return 'asset' }
        default { return 'invalid' }
    }
}

function Get-CsvValue {
    param($Row, [string[]]$Names)
    foreach ($n in $Names) {
        $p = $Row.PSObject.Properties[$n]
        if ($p -and "$($p.Value)".Trim()) { return "$($p.Value)".Trim() }
    }
    ''
}

function Invoke-CsvBulk {
    param([string]$CsvPath)
    Write-Header 'Bulk check in / out from CSV'

    if (-not $CsvPath) {
        $CsvPath = "$(Read-Host 'CSV path [Enter=back]')".Trim().Trim('"')
        if (-not $CsvPath) { return }
    }
    if (-not (Test-Path $CsvPath -PathType Leaf)) { Write-Host "File not found: $CsvPath" -ForegroundColor Red; return }

    $csv = @(Import-Csv -Path $CsvPath)
    if ($csv.Count -eq 0) { Write-Host 'The CSV has no rows.' -ForegroundColor Red; return }
    $cols = $csv[0].PSObject.Properties.Name
    if (-not ($cols | Where-Object { $_ -in 'Identifier', 'AssetTag' })) {
        Write-Host 'The CSV needs an Identifier (or AssetTag) column. See templates/bulk-template.csv.' -ForegroundColor Red
        return
    }

    $defaultType = if ($script:Ctx.Config.DefaultAssignType) { [string]$script:Ctx.Config.DefaultAssignType } else { 'user' }
    Write-Host "Validating $($csv.Count) row(s)...`n"

    # --- 1. Validate every row without changing anything ---
    $plan = [System.Collections.Generic.List[object]]::new()
    $seenAssets = @{}
    for ($i = 0; $i -lt $csv.Count; $i++) {
        $row = $csv[$i]
        $item = [pscustomobject]@{
            Line = $i + 2; Identifier = Get-CsvValue $row 'Identifier', 'AssetTag'; Action = ''
            AssetTag = ''; Model = ''; MatchedField = ''; Target = ''; WasAssignedTo = ''
            ExpectedCheckin = ''; Note = Get-CsvValue $row 'Notes', 'Note'
            Status = 'Ready'; Problem = ''; Result = ''; Detail = ''
            AssetObj = $null; TargetObj = $null; ExpectedObj = $null; NeedsTransfer = $false; BeforeObj = $null
        }
        $plan.Add($item)
        $fail = { param($msg) $item.Status = 'Error'; $item.Problem = $msg }

        $item.Action = ConvertTo-ActionName (Get-CsvValue $row 'Action')
        if (-not $item.Action) { & $fail "Action must be Checkout or Checkin (got '$(Get-CsvValue $row 'Action')')"; continue }
        if (-not $item.Identifier) { & $fail 'No identifier'; continue }

        $m = Resolve-AssetInteractive -Index $script:Ctx.Index -Value $item.Identifier
        if (-not $m) { & $fail 'Asset not found'; continue }
        $a = $m.Asset
        $item.AssetObj = $a; $item.AssetTag = $a.AssetTag; $item.Model = $a.Model; $item.MatchedField = $m.Field
        $item.WasAssignedTo = Get-AssignedLabel $a

        if ($seenAssets.ContainsKey($a.Id)) { & $fail "Same asset as line $($seenAssets[$a.Id])"; continue }
        $seenAssets[$a.Id] = $item.Line

        if ($item.Action -eq 'Checkin') {
            if (-not $a.AssignedType) { $item.Status = 'Skip'; $item.Problem = 'Already checked in' }
            continue
        }

        # Checkout checks
        $assignTo = Get-CsvValue $row 'AssignTo', 'AssignedTo', 'User'
        if (-not $assignTo) { & $fail 'AssignTo is empty'; continue }
        $type = ConvertTo-TargetType (Get-CsvValue $row 'AssignType', 'Type')
        if ($type -eq 'invalid') { & $fail 'AssignType must be User, Location or Asset'; continue }
        if (-not $type) { $type = $defaultType }

        $t = Resolve-Target -Type $type -Value $assignTo
        if (-not $t) { & $fail "$type '$assignTo' not found"; continue }
        $item.TargetObj = $t; $item.Target = $t.Label

        try {
            $item.ExpectedObj = ConvertTo-DateInput (Get-CsvValue $row 'ExpectedCheckin', 'ExpectedReturn', 'DueDate')
            $item.ExpectedCheckin = Format-Date $item.ExpectedObj
        }
        catch { & $fail $_.Exception.Message; continue }

        if ($a.StatusType -and $a.StatusType -ne 'deployable') { & $fail "Status is '$($a.Status)' - can't be checked out"; continue }
        if ($t.Type -eq 'asset' -and $t.Id -eq $a.Id) { & $fail "Can't check an asset out to itself"; continue }
        if ($a.AssignedType -eq $t.Type -and $a.AssignedId -eq $t.Id) { $item.Status = 'Skip'; $item.Problem = 'Already checked out to them'; continue }
        if ($a.AssignedType) { $item.NeedsTransfer = $true; $item.Problem = "Currently checked out to $($item.WasAssignedTo)" }
    }

    # --- 2. Show the plan ---
    $ready    = @($plan | Where-Object Status -eq 'Ready')
    $transfer = @($ready | Where-Object NeedsTransfer)
    $errors   = @($plan | Where-Object Status -eq 'Error')
    $skips    = @($plan | Where-Object Status -eq 'Skip')

    Write-Host "`nValidation results:" -ForegroundColor Cyan
    Write-Host ('  Ready        {0}  ({1} check-out, {2} check-in)' -f $ready.Count, @($ready | Where-Object Action -eq 'Checkout').Count, @($ready | Where-Object Action -eq 'Checkin').Count)
    Write-Host ('  Skip         {0}  (nothing to do)' -f $skips.Count)
    Write-Host ('  Errors       {0}' -f $errors.Count)
    foreach ($e in $errors | Select-Object -First 20) { Write-Host "   Line $($e.Line) ($($e.Identifier)): $($e.Problem)" -ForegroundColor Red }
    if ($errors.Count -gt 20) { Write-Host "   ...and $($errors.Count - 20) more (all listed in the report)" -ForegroundColor Red }
    foreach ($s in $skips | Select-Object -First 10) { Write-Host "   Line $($s.Line) ($($s.AssetTag)): $($s.Problem)" -ForegroundColor DarkYellow }

    if ($transfer.Count) {
        Write-Host "`n$($transfer.Count) asset(s) already assigned:" -ForegroundColor Yellow
        foreach ($t in $transfer | Select-Object -First 10) { Write-Host "   $($t.AssetTag): $($t.WasAssignedTo) -> $($t.Target)" }
        if ((Read-Choice '  [T]ransfer or [S]kip?' @('T', 'S')) -eq 'S') {
            foreach ($t in $transfer) { $t.Status = 'Skip'; $t.Problem = "Not transferred: $($t.Problem)" }
        }
    }

    $toDo = @($plan | Where-Object Status -eq 'Ready')
    if ($toDo.Count -eq 0) {
        Write-Host "`nNothing to do." -ForegroundColor DarkYellow
    }
    elseif (Read-YesNo "`nProcess $($toDo.Count) change(s) now?") {
        # --- 3. Do it ---
        $n = 0
        foreach ($item in $toDo) {
            $n++
            Write-Progress -Activity 'Updating Snipe-IT' -Status "$n of $($toDo.Count)" -PercentComplete ($n / $toDo.Count * 100)
            $outcome = Invoke-AssetAction -Asset $item.AssetObj -Action $item.Action -Target $item.TargetObj -Note $item.Note `
                -ExpectedCheckin $item.ExpectedObj -Transfer:$item.NeedsTransfer
            $item.Result = $outcome.Result; $item.Detail = $outcome.Detail
            if ($outcome.Result -eq 'Done') { $item.BeforeObj = $outcome.Before }
            $extra = if ($item.Action -eq 'Checkout') { "-> $($item.Target)" } else { 'checked in' }
            Write-ActionLine -Tag $item.AssetTag -Outcome $outcome -Extra $extra
        }
        Write-Progress -Activity 'Updating Snipe-IT' -Completed

        # --- Offer to reverse the whole batch ---
        $changed = @($toDo | Where-Object { $_.Result -eq 'Done' -and $_.BeforeObj })
        if ($changed.Count) {
            $answer = Read-Host "`nType UNDO to reverse all $($changed.Count) change(s) from this file, or press Enter to finish"
            if (Test-UndoCommand $answer) {
                [array]::Reverse($changed)
                foreach ($item in $changed) {
                    $entry = [pscustomobject]@{ AssetId = $item.AssetObj.Id; AssetTag = $item.AssetTag; Label = "bulk $($item.Action.ToLower())"; Before = $item.BeforeObj }
                    $u = Undo-AssetChange -Entry $entry
                    Write-ActionLine -Tag $item.AssetTag -Outcome $u -Extra '- undo'
                    if ($u.Result -eq 'Done') {
                        $item.Result = 'Undone'
                        # Remove it from the undo history too
                        $h = $script:Ctx.History | Where-Object { $_.AssetId -eq $item.AssetObj.Id } | Select-Object -Last 1
                        if ($h) { [void]$script:Ctx.History.Remove($h) }
                    }
                }
            }
        }
    }
    else { Write-Host 'Cancelled - nothing changed.' -ForegroundColor DarkYellow }

    foreach ($item in $plan | Where-Object { -not $_.Result }) {
        $item.Result = if ($item.Status -eq 'Error') { 'Failed' } elseif ($item.Status -eq 'Skip') { 'Skipped' } else { 'Not run' }
        $item.Detail = $item.Problem
    }

    Write-Host "`nSummary:" -ForegroundColor Cyan
    Write-Summary $plan
    $report = $plan | Select-Object Line, Identifier, Action, AssetTag, Model, MatchedField, WasAssignedTo, Target, ExpectedCheckin, Note, Result, Detail
    Write-Host "Report: $(Save-Report -Name 'bulk' -Rows $report)"
}
