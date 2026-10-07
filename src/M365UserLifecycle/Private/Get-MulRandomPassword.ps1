function Get-MulRandomPassword {
    <#
    .SYNOPSIS
        Generates a cryptographically random initial password that meets Entra ID complexity rules.
        The value is used once for account creation and is never logged or returned to the caller.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateRange(16, 128)]
        [int]$Length = 24
    )

    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%^&*-_=+?')
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object -TypeName 'byte[]' -ArgumentList ($Length * 2)
        $rng.GetBytes($bytes)
        $chars = New-Object -TypeName System.Collections.Generic.List[char]
        for ($i = 0; $i -lt $sets.Count; $i++) { $chars.Add($sets[$i][$bytes[$i] % $sets[$i].Length]) }
        for ($i = $sets.Count; $i -lt $Length; $i++) { $chars.Add($all[$bytes[$i] % $all.Length]) }
        # Shuffle so the guaranteed characters are not always first.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = $bytes[$Length + ($i % $Length)] % ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        return -join $chars
    }
    finally {
        $rng.Dispose()
    }
}
