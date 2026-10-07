@{
    # All default rules at every severity, plus formatting rules for a consistent style.
    Severity     = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true
    Rules        = @{
        PSPlaceOpenBrace           = @{ Enable = $true; OnSameLine = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true }
        PSPlaceCloseBrace          = @{ Enable = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true; NoEmptyLineBefore = $false }
        PSUseConsistentIndentation = @{ Enable = $true; IndentationSize = 4; Kind = 'space'; PipelineIndentation = 'IncreaseIndentationForFirstPipeline' }
        PSUseCorrectCasing         = @{ Enable = $true }
        PSAvoidUsingDoubleQuotesForConstantString = @{ Enable = $false }
        PSUseCompatibleSyntax      = @{ Enable = $true; TargetVersions = @('5.1', '7.4') }
    }
}
