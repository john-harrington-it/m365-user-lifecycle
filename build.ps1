<#
.SYNOPSIS
    Runs PSScriptAnalyzer and the Pester test suite for this repository.

.DESCRIPTION
    Exits non-zero when the analyzer reports any finding or any test fails, so the same script
    works locally and in CI. Results are written to ./test-results/.

.EXAMPLE
    ./build.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipAnalyzer
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$results = Join-Path -Path $root -ChildPath 'test-results'
$null = New-Item -Path $results -ItemType Directory -Force

Import-Module -Name Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -ErrorAction Stop
Import-Module -Name PSScriptAnalyzer -ErrorAction Stop

$failed = $false

if (-not $SkipAnalyzer) {
    Write-Information -MessageData '== PSScriptAnalyzer ==' -InformationAction Continue
    $findings = @(Invoke-ScriptAnalyzer -Path (Join-Path -Path $root -ChildPath 'src') -Recurse -Settings (Join-Path -Path $root -ChildPath 'PSScriptAnalyzerSettings.psd1'))
    $findings += @(Invoke-ScriptAnalyzer -Path (Join-Path -Path $root -ChildPath 'examples') -Recurse -Settings (Join-Path -Path $root -ChildPath 'PSScriptAnalyzerSettings.psd1'))
    if ($findings.Count -gt 0) {
        $findings | Format-Table -Property Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String | Write-Information -InformationAction Continue
        $failed = $true
    }
    Write-Information -MessageData ('Analyzer findings: {0}' -f $findings.Count) -InformationAction Continue
    $findings | Select-Object -Property Severity, RuleName, ScriptName, Line, Message |
        ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path -Path $results -ChildPath 'analyzer.json') -Encoding UTF8
}

Write-Information -MessageData '== Pester ==' -InformationAction Continue
$config = New-PesterConfiguration
$config.Run.Path = Join-Path -Path $root -ChildPath 'tests'
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = Join-Path -Path $results -ChildPath 'pester.xml'
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = Join-Path -Path $root -ChildPath 'src'
$config.CodeCoverage.OutputPath = Join-Path -Path $results -ChildPath 'coverage.xml'
$run = Invoke-Pester -Configuration $config

$coverage = 0
if ($run.CodeCoverage -and $run.CodeCoverage.CommandsAnalyzedCount -gt 0) {
    $coverage = [math]::Round(100 * $run.CodeCoverage.CommandsExecutedCount / $run.CodeCoverage.CommandsAnalyzedCount, 1)
}
$summary = [ordered]@{
    Pester       = (Get-Module -Name Pester).Version.ToString()
    Analyzer     = (Get-Module -Name PSScriptAnalyzer).Version.ToString()
    PowerShell   = $PSVersionTable.PSVersion.ToString()
    Passed       = $run.PassedCount
    Failed       = $run.FailedCount
    Skipped      = $run.SkippedCount
    CoveragePct  = $coverage
}
$summary | ConvertTo-Json | Set-Content -Path (Join-Path -Path $results -ChildPath 'summary.json') -Encoding UTF8
Write-Information -MessageData ('Summary: ' + ($summary | ConvertTo-Json -Compress)) -InformationAction Continue

if ($run.FailedCount -gt 0) { $failed = $true }
if ($failed) { exit 1 }
