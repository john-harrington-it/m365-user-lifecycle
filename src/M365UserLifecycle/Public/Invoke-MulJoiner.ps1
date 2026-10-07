function Invoke-MulJoiner {
    <#
    .SYNOPSIS
        Onboards new users from a CSV: create account, license via group, groups, manager, mailbox settings.

    .DESCRIPTION
        DRY RUN BY DEFAULT. Without -Apply, every lookup runs against your tenant but nothing is
        changed; each planned change is reported with Status 'DryRun'. Add -Apply to make changes.
        With -Apply, PowerShell's -WhatIf and -Confirm work as usual.

        For each row:
          1. Pre-flight (read-only): resolve the license group, extra groups, and manager. If any
             lookup fails the row is skipped before anything is created.
          2. Create the user (cloud-only) with a random initial password that is never logged or
             returned, and ForceChangePasswordNextSignIn. Existing users are not modified; the run
             continues with the remaining steps, so the tool also completes setup for accounts
             synced from on-premises AD.
          3. Add to the license group (group-based licensing) and the extra groups, skipping
             groups the user is already in.
          4. Set the manager.
          5. Set mailbox time zone and language. Right after licensing the mailbox may not exist
             yet; the step is then reported as 'Pending'. Re-run the same CSV later: finished
             steps are skipped.

        Writes a CSV of every step to -ReportPath and a log to -LogPath.

    .PARAMETER Path
        Joiner CSV (see Import-MulJoinerCsv for columns).

    .PARAMETER InputObject
        Objects from Import-MulJoinerCsv.

    .PARAMETER Apply
        Make the changes. Without it the command is a dry run.

    .PARAMETER ReportPath
        CSV report of all steps. Default .\mul-joiner-<timestamp>.csv.

    .PARAMETER LogPath
        Log file. Default .\mul-joiner-<timestamp>.log.

    .EXAMPLE
        Connect-MgGraph -Scopes User.ReadWrite.All, Group.ReadWrite.All, MailboxSettings.ReadWrite
        Invoke-MulJoiner -Path .\joiners.csv

        Dry run: shows every change that would be made.

    .EXAMPLE
        Invoke-MulJoiner -Path .\joiners.csv -Apply -Confirm:$false

        Applies the changes without per-step prompts (after reviewing the dry run).

    .OUTPUTS
        Mul.StepResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Path')]
    [OutputType('Mul.StepResult')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'InputObject')]
        [ValidateNotNull()]
        [psobject[]]$InputObject,

        [switch]$Apply,

        [ValidateNotNullOrEmpty()]
        [string]$ReportPath = (Join-Path -Path (Get-Location).Path -ChildPath ('mul-joiner-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

        [ValidateNotNullOrEmpty()]
        [string]$LogPath = (Join-Path -Path (Get-Location).Path -ChildPath ('mul-joiner-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
    )

    begin {
        $null = Assert-MulConnection
        $script:MulLogPath = $LogPath
        $dryRun = -not $Apply
        $all = New-Object -TypeName System.Collections.Generic.List[object]
        $mode = 'APPLY'
        if ($dryRun) { $mode = 'DRY RUN (add -Apply to make changes)' }
        Write-MulLog -Message ('Joiner run started. Mode: {0}' -f $mode)
        if ($PSCmdlet.ParameterSetName -eq 'Path') { $InputObject = @(Import-MulJoinerCsv -Path $Path) }
    }

    process {
        foreach ($j in $InputObject) {
            $upn = $j.UserPrincipalName
            $steps = New-Object -TypeName System.Collections.Generic.List[object]

            # ---- 1. Pre-flight (read-only) ----
            try {
                $escaped = $upn -replace "'", "''"
                $existing = @(Get-MgUser -Filter ("userPrincipalName eq '{0}'" -f $escaped) -Property 'id', 'userPrincipalName', 'displayName')
                $licenseGroup = Resolve-MulGroup -DisplayName $j.LicenseGroup
                $extraGroups = @(foreach ($g in @($j.Groups)) { if ($g) { Resolve-MulGroup -DisplayName $g } })
                $manager = $null
                if ($j.Manager) { $manager = Get-MgUser -UserId $j.Manager -Property 'id', 'displayName' -ErrorAction Stop }
            }
            catch {
                $steps.Add((ConvertTo-MulStepResult -UserPrincipalName $upn -Step 'Preflight' -Status 'Failed' -Message ('Nothing changed for this user. {0}' -f $_.Exception.Message)))
                foreach ($s in $steps) { $all.Add($s); $s }
                continue
            }

            # ---- 2. Create user ----
            $userId = $null
            $created = $false
            if ($existing.Count -gt 0) {
                $userId = $existing[0].Id
                $steps.Add((ConvertTo-MulStepResult -UserPrincipalName $upn -Step 'CreateUser' -Status 'Skipped' -Message 'User already exists (created earlier or synced from AD); continuing with remaining steps.'))
            }
            else {
                $body = @{
                    AccountEnabled    = $true
                    DisplayName       = $j.DisplayName
                    GivenName         = $j.FirstName
                    Surname           = $j.LastName
                    UserPrincipalName = $upn
                    MailNickname      = $j.MailNickname
                    UsageLocation     = $j.UsageLocation
                    PasswordProfile   = @{ ForceChangePasswordNextSignIn = $true; Password = (Get-MulRandomPassword) }
                }
                foreach ($optional in 'Department', 'JobTitle', 'OfficeLocation') { if ($j.$optional) { $body[$optional] = $j.$optional } }

                $r = Invoke-MulStep -Cmdlet $PSCmdlet -DryRun $dryRun -UserPrincipalName $upn -Step 'CreateUser' -Description ('Create cloud user {0} ({1}, usage location {2})' -f $j.DisplayName, $upn, $j.UsageLocation) -Action {
                    New-MgUser @body -ErrorAction Stop
                }
                $body.PasswordProfile = $null
                if ($r.Status -eq 'Success') {
                    $created = $true
                    $userId = $r.Data.Id
                    $r.Message = '{0} (id {1})' -f $r.Message, $userId
                    $r.PSObject.Properties.Remove('Data')
                }
                $steps.Add($r)
                if ($r.Status -eq 'Failed') { foreach ($s in $steps) { $all.Add($s); $s }; continue }
            }

            # ---- 3. Groups (license group first) ----
            $current = @()
            if ($userId -and -not $created) { $current = @(Get-MgUserMemberOf -UserId $userId -All | ForEach-Object { $_.Id }) }
            $targets = @(@{ Group = $licenseGroup; Step = 'AddToLicenseGroup' }) + @($extraGroups | ForEach-Object { @{ Group = $_; Step = 'AddToGroup' } })
            foreach ($t in $targets) {
                $grp = $t.Group
                if ($grp.Id -in $current) {
                    $steps.Add((ConvertTo-MulStepResult -UserPrincipalName $upn -Step $t.Step -Status 'Skipped' -Message ('Already a member of {0}' -f $grp.DisplayName)))
                    continue
                }
                $steps.Add((Invoke-MulStep -Cmdlet $PSCmdlet -DryRun ($dryRun -or -not $userId) -UserPrincipalName $upn -Step $t.Step -Description ('Add to group {0}' -f $grp.DisplayName) -Action {
                            New-MgGroupMember -GroupId $grp.Id -DirectoryObjectId $userId -ErrorAction Stop
                        }))
            }

            # ---- 4. Manager ----
            if ($manager) {
                $steps.Add((Invoke-MulStep -Cmdlet $PSCmdlet -DryRun ($dryRun -or -not $userId) -UserPrincipalName $upn -Step 'SetManager' -Description ('Set manager to {0}' -f $manager.DisplayName) -Action {
                            Set-MgUserManagerByRef -UserId $userId -BodyParameter @{ '@odata.id' = ('https://graph.microsoft.com/v1.0/users/{0}' -f $manager.Id) } -ErrorAction Stop
                        }))
            }

            # ---- 5. Mailbox settings ----
            if ($j.TimeZone -or $j.Locale) {
                $mbx = @{}
                if ($j.TimeZone) { $mbx['TimeZone'] = $j.TimeZone }
                if ($j.Locale) { $mbx['Language'] = @{ Locale = $j.Locale } }
                $r = Invoke-MulStep -Cmdlet $PSCmdlet -DryRun ($dryRun -or -not $userId) -UserPrincipalName $upn -Step 'MailboxSettings' -Description ('Set mailbox time zone/language ({0} {1})' -f $j.TimeZone, $j.Locale) -Action {
                    Update-MgUserMailboxSetting -UserId $userId @mbx -ErrorAction Stop
                }
                if ($r.Status -eq 'Failed' -and $created) {
                    $r.Status = 'Pending'
                    $r.Message = 'Mailbox not provisioned yet (licensing can take several minutes). Re-run the same CSV later; completed steps are skipped.'
                }
                $steps.Add($r)
            }

            foreach ($s in $steps) { $all.Add($s); $s }
        }
    }

    end {
        Export-MulReport -Result $all.ToArray() -Path $ReportPath
        $summary = ($all | Group-Object -Property Status | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ' '
        Write-MulLog -Message ('Joiner run complete. {0}. Report: {1}' -f $summary, $ReportPath)
        if ($dryRun) { Write-Information -MessageData ('Dry run complete; nothing was changed. Review {0}, then re-run with -Apply.' -f $ReportPath) -InformationAction Continue }
    }
}
