# PSScriptAnalyzer settings for BatteryPill
#
# Goal: catch real correctness/style problems (Error + Warning severity)
# while excluding rules that fight this project's intentional patterns.
#
# Why these exclusions:
#   PSAvoidUsingWriteHost
#       CheckBattery.ps1 is an interactive CLI that intentionally uses
#       Write-Host for COLORED console output (-ForegroundColor). That is
#       the correct tool for a human-facing console UI, so this rule is noise.
#
#   PSAvoidUsingPositionalParameters
#       The codebase intentionally uses positional args for common cmdlets
#       (Join-Path, New-Object, Start-Process "<url>") for readability.
#
#   PSUseShouldProcessForStateChangingFunctions
#       The widget defines helper functions (Set-*, Save-*) that mutate the
#       in-memory config / draw the UI; they are not exported cmdlets and
#       wiring ShouldProcess into a GUI event loop would be inappropriate.
#
#   PSAvoidGlobalVars
#       A Global\ mutex name and a small number of script/global refs are
#       deliberate (single-instance lock + WinForms scriptblock scoping,
#       documented in CLAUDE.md as the $script:floatingBar pattern).
#
#   PSUseBOMForUnicodeEncodedFile
#       Sources are UTF-8 (no BOM) on purpose; PS2EXE handles them fine and
#       a BOM is not wanted in files round-tripped through git on Linux.
#
#   PSReviewUnusedParameter
#       WinForms event handlers ($sender, $eventArgs) frequently go unused
#       but must keep their signature; flagging them is pure noise.
#
#   PSUseProcessBlockForPipelineCommand / PSAvoidUsingCmdletAliases handled
#       separately below (aliases stay an error — they hurt readability).

@{
    # Run the full default rule set, then trim the ones above.
    IncludeDefaultRules = $true

    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSAvoidUsingPositionalParameters',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidGlobalVars',
        'PSUseBOMForUnicodeEncodedFile',
        'PSReviewUnusedParameter'
    )

    Rules = @{
        # Aliases hurt readability in a shipped script — keep this on.
        PSAvoidUsingCmdletAliases = @{
            Enable = $true
        }
        # Be explicit about consistent indentation/whitespace expectations.
        PSUseConsistentIndentation = @{
            Enable          = $true
            Kind            = 'space'
            IndentationSize = 4
        }
        PSUseConsistentWhitespace = @{
            Enable         = $true
            CheckOpenBrace = $true
            CheckOpenParen = $true
            CheckOperator  = $false
            CheckSeparator = $true
        }
    }
}
