# tests\AutoTheme.Tests.ps1
#
# Theme = "auto" ("Auto (follow Windows)") must follow a Windows light/dark
# switch while the widget runs. It used to read the Windows theme only at
# startup or on a Settings change. Test-AutoThemeStale is the decision the
# UserPreferenceChanged handler makes on every settings broadcast.

. (Join-Path $PSScriptRoot '_harness.ps1')
. (Import-WidgetFunction 'Test-AutoThemeStale')

Write-Host 'AutoTheme.Tests.ps1'

Test-Case 'auto theme: Windows switched to light under a dark pill - re-theme' {
    Assert-Equal $true (Test-AutoThemeStale -ThemeSetting 'auto' -IsDark $true -SystemLight $true)
}

Test-Case 'auto theme: Windows switched to dark under a light pill - re-theme' {
    Assert-Equal $true (Test-AutoThemeStale -ThemeSetting 'auto' -IsDark $false -SystemLight $false)
}

Test-Case 'auto theme: already matching - leave it alone (the broadcast fires for many settings)' {
    Assert-Equal $false (Test-AutoThemeStale -ThemeSetting 'auto' -IsDark $true -SystemLight $false)
    Assert-Equal $false (Test-AutoThemeStale -ThemeSetting 'auto' -IsDark $false -SystemLight $true)
}

Test-Case 'auto theme: an explicit dark or light choice never follows Windows' {
    Assert-Equal $false (Test-AutoThemeStale -ThemeSetting 'dark' -IsDark $true -SystemLight $true)
    Assert-Equal $false (Test-AutoThemeStale -ThemeSetting 'light' -IsDark $false -SystemLight $false)
}

exit (Complete-Tests)
