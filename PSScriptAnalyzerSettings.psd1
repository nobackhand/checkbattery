# PSScriptAnalyzerSettings.psd1
#
# Static-analysis configuration for BatteryPill. tools\check-source.ps1 runs
# PSScriptAnalyzer with this settings file and FAILS on any Error or Warning,
# so the verify.sh log stays warning-free.
#
# Every rule below is switched off deliberately, with the one-line reason it
# does not apply to this codebase. Anything not listed here is enforced: if the
# analyzer starts reporting a new warning, fix it - do not extend this list
# without a real justification.
@{
    # Information-level rules are enforced too (they were advisory-only before).
    # That turns on PSUseOutputTypeCorrectly - the analyzer's return-type rule,
    # which checks a declared [OutputType] against what a function actually
    # emits - and PSAvoidUsingPositionalParameters, which makes a call site
    # name the parameters it is binding to instead of relying on position.
    Severity = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # BatteryPill is a console/GUI app: Write-Host IS the CLI's user-facing output channel (CheckBattery.ps1, build + dev tooling), not stray debug logging.
        'PSAvoidUsingWriteHost',

        # $sender/$s are the WinForms delegate's own parameter names; PS 5.1 only treats $sender as automatic inside Register-ObjectEvent actions, which this script never uses.
        'PSAvoidAssignmentToAutomaticVariable',

        # Same reason: WinForms event handlers must declare (sender, eventArgs) to match the delegate signature even when the handler ignores sender.
        'PSReviewUnusedParameter',

        # These are private helpers inside a single-file GUI app, never exported cmdlets, so -WhatIf/-Confirm plumbing would add ceremony no caller can use.
        'PSUseShouldProcessForStateChangingFunctions',

        # Deliberate best-effort paths (GDI+ disposal, registry/theme probes, timer teardown): a failure there must never surface an error to the user mid-paint.
        'PSAvoidUsingEmptyCatchBlock',

        # Get-PowerPlans/Get-PillDimensions/Assert-Throws return collections; the plural names are accurate and renaming them would churn call sites for no reader benefit.
        'PSUseSingularNouns'
    )
}
