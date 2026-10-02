# Reports: current loans, overdue returns, what one person has, and caddy contents.

function Show-ReportRows {
    param([string]$Title, [string]$Name, $Rows)
    $Rows = @($Rows | Where-Object { $_ })
    Write-Host "`n$Title - $($Rows.Count) row(s)" -ForegroundColor Cyan
    if ($Rows.Count -eq 0) { return }
    $Rows | Select-Object -First 25 | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    if ($Rows.Count -gt 25) { Write-Host "(showing the first 25 - the full list is in the report)" -ForegroundColor DarkGray }
    Write-Host "Report: $(Save-Report -Name $Name -Rows $Rows)"
}

function ConvertTo-LoanRow {
    param($Asset)
    $today = (Get-Date).Date
    $overdue = if ($Asset.ExpectedCheckin -and ([datetime]$Asset.ExpectedCheckin).Date -lt $today) {
        ($today - ([datetime]$Asset.ExpectedCheckin).Date).Days
    } else { 0 }
    [pscustomobject]@{
        AssetTag       = $Asset.AssetTag
        Model          = $Asset.Model
        Serial         = $Asset.Serial
        CheckedOutTo   = (Get-AssignedLabel $Asset)
        CheckedOut     = Format-Date $Asset.LastCheckout
        ExpectedReturn = Format-Date $Asset.ExpectedCheckin
        DaysOverdue    = $overdue
    }
}

function Invoke-Reports {
    Write-Header 'Reports'
    Write-Host 'Refreshing asset list from Snipe-IT so reports are up to date...'
    Update-AssetCache

    while ($true) {
        Write-Host "`n  [1] Everything checked out to people"
        Write-Host '  [2] Overdue returns'
        Write-Host '  [3] What does one person have?'
        Write-Host '  [4] Caddy contents'
        Write-Host '  [B] Back to main menu'
        $choice = Read-Choice '  Choice' @('1', '2', '3', '4', 'B')
        $assets = @($script:Ctx.Index.ById.Values)

        switch ($choice) {
            '1' {
                $rows = $assets | Where-Object AssignedType -eq 'user' | ForEach-Object { ConvertTo-LoanRow $_ } | Sort-Object CheckedOutTo, AssetTag
                Show-ReportRows 'Assets checked out to people' 'loans' $rows
            }
            '2' {
                $rows = $assets | Where-Object AssignedType | ForEach-Object { ConvertTo-LoanRow $_ } |
                    Where-Object { $_.DaysOverdue -gt 0 } | Sort-Object DaysOverdue -Descending
                Show-ReportRows 'Overdue returns' 'overdue' $rows
            }
            '3' {
                $u = Resolve-UserInteractive -Value (Read-Host '  Name, username or email')
                if ($u) {
                    $rows = $assets | Where-Object { $_.AssignedType -eq 'user' -and $_.AssignedId -eq $u.Id } | ForEach-Object { ConvertTo-LoanRow $_ }
                    Show-ReportRows "Assets with $($u.Label)" 'user-assets' $rows
                }
            }
            '4' {
                $rows = $assets | Where-Object { Test-LooksLikeCaddy $_ } | ForEach-Object {
                    $caddy = $_
                    $inside = @($assets | Where-Object { $_.AssignedType -eq 'asset' -and $_.AssignedId -eq $caddy.Id })
                    [pscustomobject]@{
                        Caddy       = Get-AssetShortLabel $caddy
                        Location    = if ($caddy.AssignedName) { $caddy.AssignedName } else { $caddy.Location }
                        Laptops     = $inside.Count
                        NotReady    = @($inside | Where-Object { $_.StatusType -and $_.StatusType -ne 'deployable' }).Count
                        AssetTags   = ($inside.AssetTag | Sort-Object) -join ', '
                    }
                } | Sort-Object Caddy
                Show-ReportRows 'Caddy contents (according to Snipe-IT)' 'caddies' $rows
            }
            'B' { return }
        }
    }
}
