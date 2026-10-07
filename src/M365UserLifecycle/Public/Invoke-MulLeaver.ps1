function Invoke-MulLeaver {
    <#
    .SYNOPSIS
        Offboards users from a CSV: block sign-in, revoke sessions, shared mailbox, auto-reply, delegate access, OneDrive hand-off, remove licenses.

    .DESCRIPTION
        DRY RUN BY DEFAULT. Without -Apply, all lookups run but nothing is changed; each planned
        change is reported with Status 'DryRun'. With -Apply, ConfirmImpact is High, so PowerShell
        prompts for each step unless -Confirm:$false is passed.

        Steps, in this order (the order matters):
          1. Pre-flight (read-only): user, delegate, and mailbox must resolve.
          2. Block sign-in (accountEnabled = false).
          3. Revoke refresh tokens and sessions.
          4. Convert the mailbox to a shared mailbox (Exchange Online).
          5. Set an internal and external auto-reply.
          6. Grant the delegate Full Access to the mailbox.
          7. Share the OneDrive root with the delegate (edit rights, sign-in required).
          8. Remove licenses: group-based licenses by removing the user from the licensing groups,
             and direct assignments with Set-MgUserLicense.

        Safety: license removal is BLOCKED automatically unless the mailbox conversion succeeded
        or the mailbox was already shared, because removing the license from a user mailbox
        starts its deletion clock. The account is never deleted.

    .PARAMETER Path
        Leaver CSV (see Import-MulLeaverCsv for columns).

    .PARAMETER InputObject
        Objects from Import-MulLeaverCsv.

    .PARAMETER Apply
        Make the changes. Without it the command is a dry run.

    .PARAMETER SkipOneDriveHandoff
        Do not share the OneDrive with the delegate (for example when OneDrive retention
        auto-assigns the manager instead).

    .PARAMETER ReportPath
        CSV report of all steps. Default .\mul-leaver-<timestamp>.csv.

    .PARAMETER LogPath
        Log file. Default .\mul-leaver-<timestamp>.log.

    .EXAMPLE
        Connect-MgGraph -Scopes User.ReadWrite.All, Group.ReadWrite.All, Files.ReadWrite.All
        Connect-ExchangeOnline
        Invoke-MulLeaver -Path .\leavers.csv

        Dry run.

    .EXAMPLE
        Invoke-MulLeaver -Path .\leavers.csv -Apply

        Applies, prompting before each step.

    .OUTPUTS
        Mul.StepResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Path')]
    [OutputType('Mul.StepResult')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'InputObject')]
        [ValidateNotNull()]
        [psobject[]]$InputObject,

        [switch]$Apply,

        [switch]$SkipOneDriveHandoff,

        [ValidateNotNullOrEmpty()]
        [string]$ReportPath = (Join-Path -Path (Get-Location).Path -ChildPath ('mul-leaver-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

        [ValidateNotNullOrEmpty()]
        [string]$LogPath = (Join-Path -Path (Get-Location).Path -ChildPath ('mul-leaver-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
    )

    begin {
        $null = Assert-MulConnection -RequireExchange
        $script:MulLogPath = $LogPath
        $dryRun = -not $Apply
        $all = New-Object -TypeName System.Collections.Generic.List[object]
        $mode = 'APPLY'
        if ($dryRun) { $mode = 'DRY RUN (add -Apply to make changes)' }
        Write-MulLog -Message ('Leaver run started. Mode: {0}' -f $mode)
        if ($PSCmdlet.ParameterSetName -eq 'Path') { $InputObject = @(Import-MulLeaverCsv -Path $Path) }
    }

    process {
        foreach ($l in $InputObject) {
            $upn = $l.UserPrincipalName
            $steps = New-Object -TypeName System.Collections.Generic.List[object]

            # ---- 1. Pre-flight (read-only) ----
            try {
                $user = Get-MgUser -UserId $upn -Property 'id', 'displayName', 'accountEnabled', 'licenseAssignmentStates', 'assignedLicenses' -ErrorAction Stop
                $delegate = $null
                if ($l.DelegateTo) { $delegate = Get-MgUser -UserId $l.DelegateTo -Property 'id', 'displayName', 'mail', 'userPrincipalName' -ErrorAction Stop }
                $mailbox = Get-Mailbox -Identity $upn -ErrorAction Stop
            }
            catch {
                $steps.Add((ConvertTo-MulStepResult -UserPrincipalName $upn -Step 'Preflight' -Status 'Failed' -Message ('Nothing changed for this user. {0}' -f $_.Exception.Message)))
                foreach ($s in $steps) { $all.Add($s); $s }
                continue
            }
            $userId = $user.Id

            # ---- 2. Block sign-in ----
            if ($user.AccountEnabled -eq $false) {
                $steps.Add((ConvertTo-MulStepResult -UserPrincipalName $upn -Step 'BlockSignIn' -Status 'Skipped' -Message 'Sign-in already blocked'))
            }
            else {
                $steps.Add((Invoke-MulStep -Cmdlet $PSCmdlet -DryRun $dryRun -UserPrincipalName $upn -Step 'BlockSignIn' -Description 'Block sign-in' -Action {
                            Update-MgUser -UserId $userId -AccountEnabled:$false -ErrorAction Stop
                        }))
            }

            # ---- 3. Revoke sessions ----
            $steps.Add((Invoke-MulStep -Cmdlet $PSCmdlet -DryRun $dryRun -UserPrincipalName $upn -Step 'RevokeSessions' -Description 'Revoke refresh tokens and sign-in sessions' -Action {
                        $null = Revoke-MgUserSignInSession -UserId $userId -ErrorAction Stop
                    }))

            # ---- 4. Convert to shared mailbox ----
            if ([string]$mailbox.RecipientTypeDetails -eq 'SharedMailbox') {
                $convert = ConvertTo-MulStepResult -UserPrincipalName $upn -Step 'ConvertToShared' -Status 'Skipped' -Message 'Mailbox is already shared'
            }
            else {
                $convert = Invoke-MulStep -Cmdlet $PSCmdlet -DryRun $dryRun -UserPrincipalName $upn -Step 'ConvertToShared' -Description 'Convert mailbox to shared' -Action {
                    Set-Mailbox -Identity $upn -Type Shared -ErrorAction Stop
                }
            }
            $steps.Add($convert)

            # ---- 5. Auto-reply ----
            $message = $l.AutoReplyMessage
            if (-not $message -and $delegate) {
                $contact = $delegate.Mail
                if (-not $contact) { $contact = $delegate.UserPrincipalName }
                $message = 'Thank you for your message. {0} is no longer with the organization. Please contact {1} at {2}.' -f $user.DisplayName, $delegate.DisplayName, $contact
            }
            if ($message) {
                $steps.Add((Invoke-MulStep -Cmdlet $PSCmdlet -DryRun $dryRun -UserPrincipalName $upn -Step 'AutoReply' -Description 'Enable internal and external auto-reply' -Action {
                            Set-MailboxAutoReplyConfiguration -Identity $upn -AutoReplyState Enabled -InternalMessage $message -ExternalMessage $message -ExternalAudience All -ErrorAction Stop
                        }))
            }
            else {
                $steps.Add((ConvertTo-MulStepResult -UserPrincipalName $upn -Step 'AutoReply' -Status 'Skipped' -Message 'No AutoReplyMessage or DelegateTo in CSV'))
            }

            # ---- 6. Mailbox delegate and 7. OneDrive hand-off ----
            if ($delegate) {
                $steps.Add((Invoke-MulStep -Cmdlet $PSCmdlet -DryRun $dryRun -UserPrincipalName $upn -Step 'MailboxDelegate' -Description ('Grant {0} Full Access to the mailbox' -f $delegate.UserPrincipalName) -Action {
                            $null = Add-MailboxPermission -Identity $upn -User $delegate.UserPrincipalName -AccessRights FullAccess -InheritanceType All -AutoMapping $true -ErrorAction Stop
                        }))

                if ($SkipOneDriveHandoff) {
                    $steps.Add((ConvertTo-MulStepResult -UserPrincipalName $upn -Step 'OneDriveHandoff' -Status 'Skipped' -Message '-SkipOneDriveHandoff specified'))
                }
                else {
                    $steps.Add((Invoke-MulStep -Cmdlet $PSCmdlet -DryRun $dryRun -UserPrincipalName $upn -Step 'OneDriveHandoff' -Description ('Share OneDrive with {0} (edit, sign-in required)' -f $delegate.UserPrincipalName) -Action {
                                $drive = Get-MgUserDrive -UserId $userId -ErrorAction Stop
                                $invite = @{
                                    recipients     = @(@{ email = $delegate.UserPrincipalName })
                                    roles          = @('write')
                                    requireSignIn  = $true
                                    sendInvitation = $true
                                    message        = ('You now have access to the OneDrive files of {0}.' -f $user.DisplayName)
                                }
                                $null = Invoke-MgInviteDriveItem -DriveId $drive.Id -DriveItemId 'root' -BodyParameter $invite -ErrorAction Stop
                            }))
                }
            }
            else {
                $steps.Add((ConvertTo-MulStepResult -UserPrincipalName $upn -Step 'MailboxDelegate' -Status 'Skipped' -Message 'No DelegateTo in CSV'))
                $steps.Add((ConvertTo-MulStepResult -UserPrincipalName $upn -Step 'OneDriveHandoff' -Status 'Skipped' -Message 'No DelegateTo in CSV'))
            }

            # ---- 8. Remove licenses (guarded) ----
            $states = @($user.LicenseAssignmentStates)
            $licenseGroups = @($states | Where-Object { $_.AssignedByGroup } | ForEach-Object { $_.AssignedByGroup } | Sort-Object -Unique)
            $directSkus = @($states | Where-Object { -not $_.AssignedByGroup } | ForEach-Object { $_.SkuId } | Sort-Object -Unique)
            if ($states.Count -eq 0) { $directSkus = @(@($user.AssignedLicenses) | ForEach-Object { $_.SkuId } | Where-Object { $_ }) }

            if ($convert.Status -notin @('Success', 'Skipped', 'DryRun', 'WhatIf')) {
                $steps.Add((ConvertTo-MulStepResult -UserPrincipalName $upn -Step 'RemoveLicenses' -Status 'Blocked' -Message ('Mailbox conversion status is {0}; license removal skipped to protect mailbox data.' -f $convert.Status)))
            }
            elseif ($licenseGroups.Count -eq 0 -and $directSkus.Count -eq 0) {
                $steps.Add((ConvertTo-MulStepResult -UserPrincipalName $upn -Step 'RemoveLicenses' -Status 'Skipped' -Message 'No licenses assigned'))
            }
            else {
                foreach ($gid in $licenseGroups) {
                    $steps.Add((Invoke-MulStep -Cmdlet $PSCmdlet -DryRun $dryRun -UserPrincipalName $upn -Step 'RemoveLicenses' -Description ('Remove from licensing group {0}' -f $gid) -Action {
                                Remove-MgGroupMemberByRef -GroupId $gid -DirectoryObjectId $userId -ErrorAction Stop
                            }))
                }
                if ($directSkus.Count -gt 0) {
                    $steps.Add((Invoke-MulStep -Cmdlet $PSCmdlet -DryRun $dryRun -UserPrincipalName $upn -Step 'RemoveLicenses' -Description ('Remove {0} directly assigned license(s)' -f $directSkus.Count) -Action {
                                $null = Set-MgUserLicense -UserId $userId -AddLicenses @() -RemoveLicenses $directSkus -ErrorAction Stop
                            }))
                }
            }

            foreach ($s in $steps) { $all.Add($s); $s }
        }
    }

    end {
        Export-MulReport -Result $all.ToArray() -Path $ReportPath
        $summary = ($all | Group-Object -Property Status | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ' '
        Write-MulLog -Message ('Leaver run complete. {0}. Report: {1}' -f $summary, $ReportPath)
        if ($dryRun) { Write-Information -MessageData ('Dry run complete; nothing was changed. Review {0}, then re-run with -Apply.' -f $ReportPath) -InformationAction Continue }
    }
}
