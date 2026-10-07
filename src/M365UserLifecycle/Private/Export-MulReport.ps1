function Export-MulReport {
    <#
    .SYNOPSIS
        Writes step results to CSV (even during -WhatIf runs).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Result,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -Path $parent)) {
        $null = New-Item -Path $parent -ItemType Directory -Force -WhatIf:$false -Confirm:$false
    }
    $Result | Select-Object -Property UserPrincipalName, Step, Status, Message, Timestamp |
        Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false
}
