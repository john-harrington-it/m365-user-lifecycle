function Import-MulJoinerCsv {
    <#
    .SYNOPSIS
        Reads and validates a joiner (new hire) CSV.

    .DESCRIPTION
        Validates every row before anything is changed and throws one error listing all problems,
        so a bad file never half-runs. Works offline (no Graph connection needed).

        Required columns: FirstName, LastName, UserPrincipalName, UsageLocation, LicenseGroup
        Optional columns: DisplayName, MailNickname, Department, JobTitle, OfficeLocation,
                          Manager (UPN), Groups (semicolon-separated display names),
                          TimeZone (for example 'Central Standard Time'), Locale (for example 'en-US')

    .PARAMETER Path
        Path to the CSV file.

    .EXAMPLE
        Import-MulJoinerCsv -Path .\joiners.csv | Format-Table UserPrincipalName, LicenseGroup, Groups

    .OUTPUTS
        Mul.Joiner
    #>
    [CmdletBinding()]
    [OutputType('Mul.Joiner')]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [string]$Path
    )

    $rows = @(Import-Csv -Path $Path)
    if ($rows.Count -eq 0) { throw ("'{0}' contains no rows." -f $Path) }

    $required = @('FirstName', 'LastName', 'UserPrincipalName', 'UsageLocation', 'LicenseGroup')
    $columns = @($rows[0].PSObject.Properties.Name)
    $missing = @($required | Where-Object { $_ -notin $columns })
    if ($missing.Count -gt 0) { throw ('Missing required column(s): {0}' -f ($missing -join ', ')) }

    $upnPattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    $errors = New-Object -TypeName System.Collections.Generic.List[string]
    $seen = @{}
    $line = 1
    $output = foreach ($row in $rows) {
        $line++
        foreach ($col in $required) {
            if ([string]::IsNullOrWhiteSpace($row.$col)) { $errors.Add(('Line {0}: {1} is empty' -f $line, $col)) }
        }
        $upn = ([string]$row.UserPrincipalName).Trim()
        if ($upn -and $upn -notmatch $upnPattern) { $errors.Add(('Line {0}: UserPrincipalName ''{1}'' is not valid' -f $line, $upn)) }
        if ($upn -and $seen.ContainsKey($upn.ToLowerInvariant())) { $errors.Add(('Line {0}: duplicate UserPrincipalName ''{1}''' -f $line, $upn)) }
        if ($upn) { $seen[$upn.ToLowerInvariant()] = $true }
        if ($row.UsageLocation -and ([string]$row.UsageLocation).Trim() -notmatch '^[A-Za-z]{2}$') { $errors.Add(('Line {0}: UsageLocation must be a 2-letter country code' -f $line)) }

        $manager = $null
        if ($columns -contains 'Manager' -and $row.Manager) {
            $manager = ([string]$row.Manager).Trim()
            if ($manager -notmatch $upnPattern) { $errors.Add(('Line {0}: Manager ''{1}'' is not a valid UPN' -f $line, $manager)) }
        }

        $get = { param($name) if ($columns -contains $name -and -not [string]::IsNullOrWhiteSpace($row.$name)) { ([string]$row.$name).Trim() } else { $null } }
        $first = ([string]$row.FirstName).Trim()
        $last = ([string]$row.LastName).Trim()
        $display = & $get 'DisplayName'
        if (-not $display) { $display = '{0} {1}' -f $first, $last }
        $nickname = & $get 'MailNickname'
        if (-not $nickname -and $upn) { $nickname = ($upn -split '@')[0] -replace '[^A-Za-z0-9._-]', '' }
        $groupList = @()
        $groupText = & $get 'Groups'
        if ($groupText) { $groupList = @($groupText -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

        [pscustomobject]@{
            PSTypeName        = 'Mul.Joiner'
            FirstName         = $first
            LastName          = $last
            DisplayName       = $display
            UserPrincipalName = $upn
            MailNickname      = $nickname
            UsageLocation     = ([string]$row.UsageLocation).Trim().ToUpperInvariant()
            LicenseGroup      = ([string]$row.LicenseGroup).Trim()
            Groups            = $groupList
            Department        = & $get 'Department'
            JobTitle          = & $get 'JobTitle'
            OfficeLocation    = & $get 'OfficeLocation'
            Manager           = $manager
            TimeZone          = & $get 'TimeZone'
            Locale            = & $get 'Locale'
        }
    }

    if ($errors.Count -gt 0) {
        throw ("Joiner CSV validation failed:`n{0}" -f ($errors -join "`n"))
    }
    $output
}
