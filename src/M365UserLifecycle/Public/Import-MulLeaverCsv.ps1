function Import-MulLeaverCsv {
    <#
    .SYNOPSIS
        Reads and validates a leaver (offboarding) CSV.

    .DESCRIPTION
        Validates every row before anything is changed and throws one error listing all problems.
        Works offline.

        Required column: UserPrincipalName
        Optional columns: DelegateTo (UPN that receives mailbox access and the OneDrive hand-off),
                          AutoReplyMessage (text; a default is built when DelegateTo is set)

    .PARAMETER Path
        Path to the CSV file.

    .EXAMPLE
        Import-MulLeaverCsv -Path .\leavers.csv

    .OUTPUTS
        Mul.Leaver
    #>
    [CmdletBinding()]
    [OutputType('Mul.Leaver')]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [string]$Path
    )

    $rows = @(Import-Csv -Path $Path)
    if ($rows.Count -eq 0) { throw ("'{0}' contains no rows." -f $Path) }
    $columns = @($rows[0].PSObject.Properties.Name)
    if ($columns -notcontains 'UserPrincipalName') { throw 'Missing required column: UserPrincipalName' }

    $upnPattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    $errors = New-Object -TypeName System.Collections.Generic.List[string]
    $seen = @{}
    $line = 1
    $output = foreach ($row in $rows) {
        $line++
        $upn = ([string]$row.UserPrincipalName).Trim()
        if (-not $upn) { $errors.Add(('Line {0}: UserPrincipalName is empty' -f $line)); continue }
        if ($upn -notmatch $upnPattern) { $errors.Add(('Line {0}: UserPrincipalName ''{1}'' is not valid' -f $line, $upn)) }
        if ($seen.ContainsKey($upn.ToLowerInvariant())) { $errors.Add(('Line {0}: duplicate UserPrincipalName ''{1}''' -f $line, $upn)) }
        $seen[$upn.ToLowerInvariant()] = $true

        $delegate = $null
        if ($columns -contains 'DelegateTo' -and $row.DelegateTo) {
            $delegate = ([string]$row.DelegateTo).Trim()
            if ($delegate -notmatch $upnPattern) { $errors.Add(('Line {0}: DelegateTo ''{1}'' is not a valid UPN' -f $line, $delegate)) }
            if ($delegate -eq $upn) { $errors.Add(('Line {0}: DelegateTo cannot be the leaver' -f $line)) }
        }
        $message = $null
        if ($columns -contains 'AutoReplyMessage' -and $row.AutoReplyMessage) { $message = ([string]$row.AutoReplyMessage).Trim() }

        [pscustomobject]@{
            PSTypeName        = 'Mul.Leaver'
            UserPrincipalName = $upn
            DelegateTo        = $delegate
            AutoReplyMessage  = $message
        }
    }

    if ($errors.Count -gt 0) {
        throw ("Leaver CSV validation failed:`n{0}" -f ($errors -join "`n"))
    }
    $output
}
