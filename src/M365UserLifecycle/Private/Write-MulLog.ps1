function Write-MulLog {
    <#
    .SYNOPSIS
        Writes a timestamped line to the verbose stream and, when configured, to the run log.
        Never pass secrets to this function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION', 'DRYRUN')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose -Message $line
    if ($Level -eq 'WARN') { Write-Warning -Message $Message }
    if ($script:MulLogPath) {
        try {
            Add-Content -Path $script:MulLogPath -Value $line -Encoding UTF8 -WhatIf:$false -Confirm:$false -ErrorAction Stop
        }
        catch {
            Write-Verbose -Message ('Could not write to log file: {0}' -f $_.Exception.Message)
        }
    }
}
