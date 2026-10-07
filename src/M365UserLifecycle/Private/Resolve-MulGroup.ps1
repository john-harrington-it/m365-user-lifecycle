function Resolve-MulGroup {
    <#
    .SYNOPSIS
        Resolves a group display name to exactly one Entra ID group, or throws.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DisplayName
    )

    $escaped = $DisplayName -replace "'", "''"
    $found = @(Get-MgGroup -Filter ("displayName eq '{0}'" -f $escaped) -Property 'id', 'displayName' -All)
    if ($found.Count -eq 0) { throw ("Group '{0}' not found." -f $DisplayName) }
    if ($found.Count -gt 1) { throw ("Group name '{0}' is ambiguous ({1} matches). Rename or use a unique name." -f $DisplayName, $found.Count) }
    return $found[0]
}
