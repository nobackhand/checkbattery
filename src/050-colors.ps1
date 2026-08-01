# ============================================================
# HELPER: STATUS COLOR & ACCENT COLOR
# ============================================================

function Get-StatusColor {
    [OutputType([System.Drawing.Color])]
    param([string]$Status)
    switch ($Status) {
        "Fully Charged" { [System.Drawing.Color]::FromArgb(0, 200, 0) }
        "Charging" { [System.Drawing.Color]::FromArgb(255, 200, 0) }
        "Critical" { [System.Drawing.Color]::Red }
        "Low" { [System.Drawing.Color]::Orange }
        "No Battery" { [System.Drawing.Color]::Gray }
        default { [System.Drawing.Color]::FromArgb(0, 180, 255) }
    }
}

# Accent color presets (index 0-7)
$script:accentPresets = @(
    [System.Drawing.Color]::FromArgb(45, 212, 100),   # 0: Green (default)
    [System.Drawing.Color]::FromArgb(60, 140, 255),   # 1: Blue
    [System.Drawing.Color]::FromArgb(160, 100, 255),  # 2: Purple
    [System.Drawing.Color]::FromArgb(0, 210, 210),    # 3: Cyan
    [System.Drawing.Color]::FromArgb(255, 105, 180),  # 4: Pink
    [System.Drawing.Color]::FromArgb(0, 180, 160),    # 5: Teal
    [System.Drawing.Color]::FromArgb(255, 160, 40),   # 6: Orange
    [System.Drawing.Color]::FromArgb(220, 220, 230)   # 7: White
)

function Get-AccentColor {
    [OutputType([System.Drawing.Color])]
    param(
        [int]$Percent,
        [bool]$IsCharging
    )
    # No battery (desktop PCs report -1): neutral slate, NOT critical red
    if ($Percent -lt 0) {
        return [System.Drawing.Color]::FromArgb(120, 130, 140)
    }
    # Yellow when charging (any level)
    if ($IsCharging) {
        return [System.Drawing.Color]::FromArgb(255, 200, 0)
    }
    # Color-coded by battery level — warning colors always override
    if ($Percent -le 10) {
        return [System.Drawing.Color]::FromArgb(255, 70, 70)   # Red - critical
    }
    if ($Percent -le 20) {
        return [System.Drawing.Color]::FromArgb(255, 140, 0)   # Orange - low
    }
    if ($Percent -le 50) {
        return [System.Drawing.Color]::FromArgb(255, 200, 0)   # Yellow - medium
    }
    # Healthy (>50%) — use selected accent color preset
    $idx = 0
    if ($null -ne $script:config -and $null -ne $script:config.AccentColorIndex) {
        $idx = [math]::Max(0, [math]::Min(7, [int]$script:config.AccentColorIndex))
    }
    # White preset (#7) is near-invisible on the light pill/popup; swap in its
    # monochrome twin - dark graphite - when the theme surface is light
    if ($idx -eq 7 -and $null -ne $script:theme -and $script:theme.PillBg.R -gt 128) {
        return [System.Drawing.Color]::FromArgb(90, 95, 105)
    }
    return $script:accentPresets[$idx]
}

