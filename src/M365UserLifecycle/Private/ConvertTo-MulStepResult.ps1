function ConvertTo-MulStepResult {
    <#
    .SYNOPSIS
        Builds a step result for steps that are skipped, blocked, or fail pre-flight.
    #>
    [CmdletBinding()]
    [OutputType('Mul.StepResult')]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName,

        [Parameter(Mandatory)]
        [string]$Step,

        [Parameter(Mandatory)]
        [ValidateSet('Skipped', 'Blocked', 'Failed', 'Pending', 'Success')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $level = 'INFO'
    if ($Status -in @('Failed', 'Blocked')) { $level = 'WARN' }
    Write-MulLog -Level $level -Message ('{0} | {1} | {2}: {3}' -f $UserPrincipalName, $Step, $Status, $Message)
    [pscustomobject]@{
        PSTypeName        = 'Mul.StepResult'
        UserPrincipalName = $UserPrincipalName
        Step              = $Step
        Status            = $Status
        Message           = $Message
        Timestamp         = Get-Date
    }
}
