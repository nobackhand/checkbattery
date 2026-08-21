# ============================================================
# HELPER: POWER PLAN MANAGEMENT
# ============================================================

# A plan id must look like a GUID before it is handed back to powercfg or shown
# as a menu item's Tag. powercfg's output is localized and version-dependent,
# so the regex above can and does match lines that are not plan rows.
$script:powerPlanGuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

function Get-PowerPlans {
    [OutputType([hashtable[]])]
    param(
        # Test seam: stands in for `powercfg /list` output when bound, so the
        # parser can be fed the malformed lines a real machine will not produce.
        [AllowNull()][string[]]$Output = $null
    )
    try {
        if ($PSBoundParameters.ContainsKey('Output')) {
            $lines = @($Output)
        } else {
            $lines = & powercfg /list 2>&1
            if ($LASTEXITCODE -ne 0) { return @() }
        }
        $result = @()
        foreach ($line in $lines) {
            if ($null -eq $line) { continue }
            if ("$line" -match 'GUID:\s+(\S+)\s+\((.+?)\)(\s+\*)?') {
                # Capture all three groups FIRST: the -notmatch below is itself a
                # regex operation and overwrites $Matches.
                $guid = $Matches[1]
                $name = $Matches[2].Trim()
                $active = [bool]$Matches[3]
                # Reject anything that is not a real plan: a non-GUID id would
                # be passed straight to `powercfg /setactive`, and a blank name
                # produces an unclickable, unlabelled menu row.
                if ($guid -notmatch $script:powerPlanGuidPattern) { continue }
                if (-not $name) { continue }
                $result += @{
                    Name     = $name
                    GUID     = $guid
                    IsActive = $active
                }
            }
        }
        return $result
    } catch { return @() }
}

function Set-ActivePowerPlan {
    [OutputType([bool])]
    param([AllowNull()][string]$PlanGUID)
    # Validate before invoking: the id arrives from a menu item's Tag, which was
    # filled from powercfg's own (localized, parsed) output.
    if (-not $PlanGUID -or $PlanGUID -notmatch $script:powerPlanGuidPattern) { return $false }
    try {
        & powercfg /setactive $PlanGUID 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Update-PowerPlanMenu {
    [OutputType([void])]
    param([System.Windows.Forms.ToolStripMenuItem]$MenuItem)
    # ToolStripItemCollection.Clear() detaches items but does NOT dispose them,
    # and this runs on EVERY context-menu Opening - both menus, for the whole
    # life of a widget meant to sit in the tray for days. Each right-click
    # abandoned one ToolStripMenuItem per power plan, each holding its own
    # native resources. Dispose them on the way out.
    $stale = @($MenuItem.DropDownItems)
    $MenuItem.DropDownItems.Clear()
    foreach ($old in $stale) { if ($null -ne $old) { $old.Dispose() } }
    $plans = Get-PowerPlans
    foreach ($plan in $plans) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($plan.Name)
        $item.Checked = $plan.IsActive
        $item.Tag = $plan.GUID
        $item.Add_Click({
                $guid = $this.Tag
                $ok = Set-ActivePowerPlan -PlanGUID $guid
                if (-not $ok) {
                    Show-BatteryNotification -Message "Admin rights needed" -SubMessage "Cannot switch power plan without elevation"
                }
            })
        $MenuItem.DropDownItems.Add($item) | Out-Null
    }
    if ($plans.Count -eq 0) {
        $noItem = New-Object System.Windows.Forms.ToolStripMenuItem("Not available")
        $noItem.Enabled = $false
        $MenuItem.DropDownItems.Add($noItem) | Out-Null
    }
    # Re-apply dark theming to the freshly-rebuilt submenu items
    if (Get-Command Set-DarkMenuItem -ErrorAction SilentlyContinue) { Set-DarkMenuItem -Item $MenuItem }
}

