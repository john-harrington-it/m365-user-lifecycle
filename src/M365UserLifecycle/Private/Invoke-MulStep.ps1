function Invoke-MulStep {
    <#
    .SYNOPSIS
        Runs one lifecycle step with dry-run, ShouldProcess, logging, and a uniform result object.
    .DESCRIPTION
        ShouldProcess is evaluated on the calling command (-Cmdlet) so -WhatIf and -Confirm given to
        the public command apply. If the action returns a string it is appended to the message; any
        other object is attached as a transient 'Data' property for the caller to consume.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Mul.StepResult')]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet]$Cmdlet,

        [Parameter(Mandatory)]
        [bool]$DryRun,

        [Parameter(Mandatory)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory)]
        [string]$Step,

        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $result = [pscustomobject]@{
        PSTypeName        = 'Mul.StepResult'
        UserPrincipalName = $UserPrincipalName
        Step              = $Step
        Status            = ''
        Message           = $Description
        Timestamp         = Get-Date
    }

    if ($DryRun) {
        $result.Status = 'DryRun'
        Write-MulLog -Level 'DRYRUN' -Message ('{0} | {1} | {2}' -f $UserPrincipalName, $Step, $Description)
        return $result
    }

    if (-not $Cmdlet.ShouldProcess($UserPrincipalName, $Description)) {
        $result.Status = 'Declined'
        if ($WhatIfPreference) { $result.Status = 'WhatIf' }
        return $result
    }

    try {
        $output = & $Action
        $result.Status = 'Success'
        if ($output -is [string] -and $output) { $result.Message = '{0} ({1})' -f $Description, $output }
        elseif ($null -ne $output) { $result | Add-Member -MemberType NoteProperty -Name 'Data' -Value $output }
        Write-MulLog -Level 'ACTION' -Message ('{0} | {1} | {2}' -f $UserPrincipalName, $Step, $result.Message)
    }
    catch {
        $result.Status = 'Failed'
        $result.Message = '{0}: {1}' -f $Description, $_.Exception.Message
        Write-MulLog -Level 'ERROR' -Message ('{0} | {1} | {2}' -f $UserPrincipalName, $Step, $result.Message)
    }
    return $result
}
