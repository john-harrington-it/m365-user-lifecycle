# Unit tests for M365UserLifecycle. No tenant is needed: Microsoft Graph and Exchange Online
# cmdlets are stubbed and mocked, so the suite runs anywhere PowerShell runs.

BeforeAll {
    $stubs = @{
        'Get-MgContext'                     = { [CmdletBinding()] param() }
        'Get-MgUser'                        = { [CmdletBinding()] param($UserId, $Filter, $Property) }
        'New-MgUser'                        = { [CmdletBinding()] param($AccountEnabled, $DisplayName, $GivenName, $Surname, $UserPrincipalName, $MailNickname, $UsageLocation, $PasswordProfile, $Department, $JobTitle, $OfficeLocation) }
        'Update-MgUser'                     = { [CmdletBinding()] param($UserId, [switch]$AccountEnabled) }
        'Get-MgGroup'                       = { [CmdletBinding()] param($Filter, $Property, [switch]$All) }
        'New-MgGroupMember'                 = { [CmdletBinding()] param($GroupId, $DirectoryObjectId) }
        'Remove-MgGroupMemberByRef'         = { [CmdletBinding()] param($GroupId, $DirectoryObjectId) }
        'Get-MgUserMemberOf'                = { [CmdletBinding()] param($UserId, [switch]$All) }
        'Set-MgUserManagerByRef'            = { [CmdletBinding()] param($UserId, $BodyParameter) }
        'Update-MgUserMailboxSetting'       = { [CmdletBinding()] param($UserId, $TimeZone, $Language) }
        'Revoke-MgUserSignInSession'        = { [CmdletBinding()] param($UserId) }
        'Set-MgUserLicense'                 = { [CmdletBinding()] param($UserId, $AddLicenses, $RemoveLicenses) }
        'Get-MgUserDrive'                   = { [CmdletBinding()] param($UserId) }
        'Invoke-MgInviteDriveItem'          = { [CmdletBinding()] param($DriveId, $DriveItemId, $BodyParameter) }
        'Get-Mailbox'                       = { [CmdletBinding()] param($Identity) }
        'Set-Mailbox'                       = { [CmdletBinding()] param($Identity, $Type) }
        'Set-MailboxAutoReplyConfiguration' = { [CmdletBinding()] param($Identity, $AutoReplyState, $InternalMessage, $ExternalMessage, $ExternalAudience) }
        'Add-MailboxPermission'             = { [CmdletBinding()] param($Identity, $User, $AccessRights, $InheritanceType, $AutoMapping) }
    }
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            $null = New-Item -Path "function:global:$name" -Force -Value $stubs[$name]
        }
    }

    $manifest = [System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'M365UserLifecycle', 'M365UserLifecycle.psd1')
    Import-Module -Name $manifest -Force

    $script:JoinerCsv = Join-Path -Path $TestDrive -ChildPath 'joiners.csv'
    @'
FirstName,LastName,UserPrincipalName,UsageLocation,LicenseGroup,Department,JobTitle,Manager,Groups,TimeZone,Locale
Avery,Smith,avery.smith@contoso.com,US,LIC-M365-E3,Litigation,Paralegal,pat.lee@contoso.com,SG-Litigation;DL-All Staff,Central Standard Time,en-US
'@ | Set-Content -Path $script:JoinerCsv

    $script:LeaverCsv = Join-Path -Path $TestDrive -ChildPath 'leavers.csv'
    @'
UserPrincipalName,DelegateTo,AutoReplyMessage
jordan.doe@contoso.com,pat.lee@contoso.com,
'@ | Set-Content -Path $script:LeaverCsv

    $script:Report = Join-Path -Path $TestDrive -ChildPath 'report.csv'
    $script:Log = Join-Path -Path $TestDrive -ChildPath 'run.log'
}

AfterAll {
    Remove-Module -Name M365UserLifecycle -Force -ErrorAction SilentlyContinue
}

Describe 'Import-MulJoinerCsv' {
    It 'parses a valid file and derives defaults' {
        $j = Import-MulJoinerCsv -Path $script:JoinerCsv
        $j.DisplayName | Should -Be 'Avery Smith'
        $j.MailNickname | Should -Be 'avery.smith'
        $j.Groups | Should -Be @('SG-Litigation', 'DL-All Staff')
        $j.UsageLocation | Should -Be 'US'
    }

    It 'reports every invalid row in one error' {
        $bad = Join-Path -Path $TestDrive -ChildPath 'bad.csv'
        @'
FirstName,LastName,UserPrincipalName,UsageLocation,LicenseGroup
A,B,not-an-upn,USA,LIC
,C,c@contoso.com,US,
D,E,c@contoso.com,US,LIC
'@ | Set-Content -Path $bad
        $err = { Import-MulJoinerCsv -Path $bad } | Should -Throw -PassThru
        $msg = $err.Exception.Message
        $msg | Should -Match "Line 2: UserPrincipalName 'not-an-upn' is not valid"
        $msg | Should -Match 'Line 2: UsageLocation must be a 2-letter'
        $msg | Should -Match 'Line 3: FirstName is empty'
        $msg | Should -Match 'Line 3: LicenseGroup is empty'
        $msg | Should -Match "Line 4: duplicate UserPrincipalName"
    }

    It 'rejects files missing required columns' {
        $bad = Join-Path -Path $TestDrive -ChildPath 'cols.csv'
        "FirstName,LastName`nA,B" | Set-Content -Path $bad
        { Import-MulJoinerCsv -Path $bad } | Should -Throw '*Missing required column*UserPrincipalName*'
    }
}

Describe 'Import-MulLeaverCsv' {
    It 'parses a valid file' {
        $l = Import-MulLeaverCsv -Path $script:LeaverCsv
        $l.UserPrincipalName | Should -Be 'jordan.doe@contoso.com'
        $l.DelegateTo | Should -Be 'pat.lee@contoso.com'
    }

    It 'rejects a delegate equal to the leaver' {
        $bad = Join-Path -Path $TestDrive -ChildPath 'self.csv'
        "UserPrincipalName,DelegateTo`na@contoso.com,a@contoso.com" | Set-Content -Path $bad
        { Import-MulLeaverCsv -Path $bad } | Should -Throw '*DelegateTo cannot be the leaver*'
    }
}

Describe 'Connection checks' {
    It 'refuses to run when Graph is not connected' {
        Mock -ModuleName M365UserLifecycle Get-MgContext { $null }
        { Invoke-MulJoiner -Path $script:JoinerCsv -ReportPath $script:Report -LogPath $script:Log } | Should -Throw '*Connect-MgGraph*'
    }
}

Describe 'Invoke-MulJoiner' {
    BeforeEach {
        Mock -ModuleName M365UserLifecycle Get-MgContext { [pscustomobject]@{ TenantId = 'tenant'; Account = 'admin@contoso.com' } }
        Mock -ModuleName M365UserLifecycle Get-MgUser -ParameterFilter { $Filter } { }
        Mock -ModuleName M365UserLifecycle Get-MgUser -ParameterFilter { $UserId -eq 'pat.lee@contoso.com' } { [pscustomobject]@{ Id = 'mgr-1'; DisplayName = 'Pat Lee' } }
        Mock -ModuleName M365UserLifecycle Get-MgGroup { [pscustomobject]@{ Id = ('grp-' + ($Filter -replace '\W', '')); DisplayName = ($Filter -replace "^displayName eq '(.*)'$", '$1') } }
        Mock -ModuleName M365UserLifecycle New-MgUser { [pscustomobject]@{ Id = 'new-user-1' } }
        Mock -ModuleName M365UserLifecycle New-MgGroupMember { }
        Mock -ModuleName M365UserLifecycle Get-MgUserMemberOf { }
        Mock -ModuleName M365UserLifecycle Set-MgUserManagerByRef { }
        Mock -ModuleName M365UserLifecycle Update-MgUserMailboxSetting { }
    }

    It 'is a dry run by default: lookups run, nothing changes' {
        $r = Invoke-MulJoiner -Path $script:JoinerCsv -ReportPath $script:Report -LogPath $script:Log -InformationAction SilentlyContinue
        Should -Invoke -ModuleName M365UserLifecycle Get-MgGroup -Times 3 -Exactly
        Should -Invoke -ModuleName M365UserLifecycle New-MgUser -Times 0 -Exactly
        Should -Invoke -ModuleName M365UserLifecycle New-MgGroupMember -Times 0 -Exactly
        ($r | Where-Object Status -NE 'DryRun') | Should -BeNullOrEmpty
        $r.Step | Should -Be @('CreateUser', 'AddToLicenseGroup', 'AddToGroup', 'AddToGroup', 'SetManager', 'MailboxSettings')
        Get-Content -Path $script:Log -Raw | Should -Match 'DRY RUN'
    }

    It 'applies every step with -Apply' {
        $r = Invoke-MulJoiner -Path $script:JoinerCsv -Apply -Confirm:$false -ReportPath $script:Report -LogPath $script:Log
        ($r | Where-Object Status -NE 'Success') | Should -BeNullOrEmpty
        Should -Invoke -ModuleName M365UserLifecycle New-MgUser -Times 1 -Exactly -ParameterFilter {
            $UserPrincipalName -eq 'avery.smith@contoso.com' -and $UsageLocation -eq 'US' -and $PasswordProfile.ForceChangePasswordNextSignIn -and $PasswordProfile.Password.Length -ge 16
        }
        Should -Invoke -ModuleName M365UserLifecycle New-MgGroupMember -Times 3 -Exactly -ParameterFilter { $DirectoryObjectId -eq 'new-user-1' }
        Should -Invoke -ModuleName M365UserLifecycle Set-MgUserManagerByRef -Times 1 -Exactly -ParameterFilter { $BodyParameter['@odata.id'] -like '*/users/mgr-1' }
        Should -Invoke -ModuleName M365UserLifecycle Update-MgUserMailboxSetting -Times 1 -Exactly -ParameterFilter { $TimeZone -eq 'Central Standard Time' -and $Language.Locale -eq 'en-US' }
    }

    It 'never writes the initial password to the log or report' {
        Mock -ModuleName M365UserLifecycle New-MgUser { Set-Variable -Name 'CapturedPassword' -Value $PasswordProfile.Password -Scope Global; [pscustomobject]@{ Id = 'new-user-1' } }
        $null = Invoke-MulJoiner -Path $script:JoinerCsv -Apply -Confirm:$false -ReportPath $script:Report -LogPath $script:Log
        $pw = $global:CapturedPassword
        $pw | Should -Not -BeNullOrEmpty
        Get-Content -Path $script:Log -Raw | Should -Not -Match ([regex]::Escape($pw))
        Get-Content -Path $script:Report -Raw | Should -Not -Match ([regex]::Escape($pw))
        Remove-Variable -Name 'CapturedPassword' -Scope Global
    }

    It 'honors -WhatIf together with -Apply' {
        $r = Invoke-MulJoiner -Path $script:JoinerCsv -Apply -WhatIf -ReportPath $script:Report -LogPath $script:Log
        Should -Invoke -ModuleName M365UserLifecycle New-MgUser -Times 0 -Exactly
        $r[0].Status | Should -Be 'WhatIf'
        Test-Path -Path $script:Report | Should -BeTrue
    }

    It 'changes nothing for a row whose group cannot be resolved' {
        Mock -ModuleName M365UserLifecycle Get-MgGroup -ParameterFilter { $Filter -like '*SG-Litigation*' } { }
        $r = @(Invoke-MulJoiner -Path $script:JoinerCsv -Apply -Confirm:$false -ReportPath $script:Report -LogPath $script:Log -WarningAction SilentlyContinue)
        $r.Count | Should -Be 1
        $r[0].Step | Should -Be 'Preflight'
        $r[0].Status | Should -Be 'Failed'
        $r[0].Message | Should -Match "Group 'SG-Litigation' not found"
        Should -Invoke -ModuleName M365UserLifecycle New-MgUser -Times 0 -Exactly
    }

    It 'is idempotent: existing users and memberships are skipped' {
        Mock -ModuleName M365UserLifecycle Get-MgUser -ParameterFilter { $Filter } { [pscustomobject]@{ Id = 'existing-1'; UserPrincipalName = 'avery.smith@contoso.com' } }
        Mock -ModuleName M365UserLifecycle Get-MgUserMemberOf { [pscustomobject]@{ Id = 'grp-displayNameeqLICM365E3' } }
        $r = Invoke-MulJoiner -Path $script:JoinerCsv -Apply -Confirm:$false -ReportPath $script:Report -LogPath $script:Log
        ($r | Where-Object Step -EQ 'CreateUser').Status | Should -Be 'Skipped'
        ($r | Where-Object Step -EQ 'AddToLicenseGroup').Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName M365UserLifecycle New-MgUser -Times 0 -Exactly
        Should -Invoke -ModuleName M365UserLifecycle New-MgGroupMember -Times 2 -Exactly -ParameterFilter { $DirectoryObjectId -eq 'existing-1' }
    }

    It 'marks mailbox settings Pending when the new mailbox is not provisioned yet' {
        Mock -ModuleName M365UserLifecycle Update-MgUserMailboxSetting { throw 'MailboxNotEnabledForRESTAPI' }
        $r = Invoke-MulJoiner -Path $script:JoinerCsv -Apply -Confirm:$false -ReportPath $script:Report -LogPath $script:Log
        ($r | Where-Object Step -EQ 'MailboxSettings').Status | Should -Be 'Pending'
    }

    It 'writes a CSV report of every step' {
        $null = Invoke-MulJoiner -Path $script:JoinerCsv -ReportPath $script:Report -LogPath $script:Log -InformationAction SilentlyContinue
        @(Import-Csv -Path $script:Report).Count | Should -Be 6
    }

    It 'accepts pipeline input from Import-MulJoinerCsv' {
        $r = Import-MulJoinerCsv -Path $script:JoinerCsv | Invoke-MulJoiner -ReportPath $script:Report -LogPath $script:Log -InformationAction SilentlyContinue
        @($r).Count | Should -Be 6
    }
}

Describe 'Invoke-MulLeaver' {
    BeforeEach {
        Mock -ModuleName M365UserLifecycle Get-MgContext { [pscustomobject]@{ TenantId = 'tenant' } }
        Mock -ModuleName M365UserLifecycle Get-MgUser -ParameterFilter { $UserId -eq 'jordan.doe@contoso.com' } {
            [pscustomobject]@{
                Id                      = 'leaver-1'
                DisplayName             = 'Jordan Doe'
                AccountEnabled          = $true
                LicenseAssignmentStates = @(
                    [pscustomobject]@{ SkuId = 'sku-e3'; AssignedByGroup = 'grp-lic-e3' }
                    [pscustomobject]@{ SkuId = 'sku-visio'; AssignedByGroup = $null }
                )
                AssignedLicenses        = @()
            }
        }
        Mock -ModuleName M365UserLifecycle Get-MgUser -ParameterFilter { $UserId -eq 'pat.lee@contoso.com' } { [pscustomobject]@{ Id = 'mgr-1'; DisplayName = 'Pat Lee'; Mail = 'pat.lee@contoso.com'; UserPrincipalName = 'pat.lee@contoso.com' } }
        Mock -ModuleName M365UserLifecycle Get-Mailbox { [pscustomobject]@{ RecipientTypeDetails = 'UserMailbox' } }
        Mock -ModuleName M365UserLifecycle Update-MgUser { }
        Mock -ModuleName M365UserLifecycle Revoke-MgUserSignInSession { $true }
        Mock -ModuleName M365UserLifecycle Set-Mailbox { }
        Mock -ModuleName M365UserLifecycle Set-MailboxAutoReplyConfiguration { }
        Mock -ModuleName M365UserLifecycle Add-MailboxPermission { }
        Mock -ModuleName M365UserLifecycle Get-MgUserDrive { [pscustomobject]@{ Id = 'drive-1' } }
        Mock -ModuleName M365UserLifecycle Invoke-MgInviteDriveItem { }
        Mock -ModuleName M365UserLifecycle Remove-MgGroupMemberByRef { }
        Mock -ModuleName M365UserLifecycle Set-MgUserLicense { }
    }

    It 'is a dry run by default' {
        $r = Invoke-MulLeaver -Path $script:LeaverCsv -ReportPath $script:Report -LogPath $script:Log -InformationAction SilentlyContinue
        foreach ($cmd in 'Update-MgUser', 'Revoke-MgUserSignInSession', 'Set-Mailbox', 'Set-MailboxAutoReplyConfiguration', 'Add-MailboxPermission', 'Invoke-MgInviteDriveItem', 'Remove-MgGroupMemberByRef', 'Set-MgUserLicense') {
            Should -Invoke -ModuleName M365UserLifecycle $cmd -Times 0 -Exactly
        }
        ($r | Where-Object Status -NE 'DryRun') | Should -BeNullOrEmpty
    }

    It 'applies all steps in a safe order' {
        $r = Invoke-MulLeaver -Path $script:LeaverCsv -Apply -Confirm:$false -ReportPath $script:Report -LogPath $script:Log
        $r.Step | Should -Be @('BlockSignIn', 'RevokeSessions', 'ConvertToShared', 'AutoReply', 'MailboxDelegate', 'OneDriveHandoff', 'RemoveLicenses', 'RemoveLicenses')
        ($r | Where-Object Status -NE 'Success') | Should -BeNullOrEmpty
        Should -Invoke -ModuleName M365UserLifecycle Update-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq 'leaver-1' -and -not $AccountEnabled }
        Should -Invoke -ModuleName M365UserLifecycle Set-Mailbox -Times 1 -Exactly -ParameterFilter { $Type -eq 'Shared' }
        Should -Invoke -ModuleName M365UserLifecycle Set-MailboxAutoReplyConfiguration -Times 1 -Exactly -ParameterFilter { $InternalMessage -match 'Jordan Doe is no longer with the organization\. Please contact Pat Lee at pat.lee@contoso.com' }
        Should -Invoke -ModuleName M365UserLifecycle Invoke-MgInviteDriveItem -Times 1 -Exactly -ParameterFilter { $DriveId -eq 'drive-1' -and $DriveItemId -eq 'root' -and $BodyParameter.roles -contains 'write' }
        Should -Invoke -ModuleName M365UserLifecycle Remove-MgGroupMemberByRef -Times 1 -Exactly -ParameterFilter { $GroupId -eq 'grp-lic-e3' -and $DirectoryObjectId -eq 'leaver-1' }
        Should -Invoke -ModuleName M365UserLifecycle Set-MgUserLicense -Times 1 -Exactly -ParameterFilter { $RemoveLicenses -contains 'sku-visio' -and $RemoveLicenses -notcontains 'sku-e3' }
    }

    It 'blocks license removal when the shared mailbox conversion fails' {
        Mock -ModuleName M365UserLifecycle Set-Mailbox { throw 'Mailbox conversion failed' }
        $r = Invoke-MulLeaver -Path $script:LeaverCsv -Apply -Confirm:$false -ReportPath $script:Report -LogPath $script:Log -WarningAction SilentlyContinue
        ($r | Where-Object Step -EQ 'ConvertToShared').Status | Should -Be 'Failed'
        ($r | Where-Object Step -EQ 'RemoveLicenses').Status | Should -Be 'Blocked'
        Should -Invoke -ModuleName M365UserLifecycle Set-MgUserLicense -Times 0 -Exactly
        Should -Invoke -ModuleName M365UserLifecycle Remove-MgGroupMemberByRef -Times 0 -Exactly
    }

    It 'skips work that is already done' {
        Mock -ModuleName M365UserLifecycle Get-Mailbox { [pscustomobject]@{ RecipientTypeDetails = 'SharedMailbox' } }
        Mock -ModuleName M365UserLifecycle Get-MgUser -ParameterFilter { $UserId -eq 'jordan.doe@contoso.com' } { [pscustomobject]@{ Id = 'leaver-1'; DisplayName = 'Jordan Doe'; AccountEnabled = $false; LicenseAssignmentStates = @(); AssignedLicenses = @() } }
        $r = Invoke-MulLeaver -Path $script:LeaverCsv -Apply -Confirm:$false -ReportPath $script:Report -LogPath $script:Log
        ($r | Where-Object Step -EQ 'BlockSignIn').Status | Should -Be 'Skipped'
        ($r | Where-Object Step -EQ 'ConvertToShared').Status | Should -Be 'Skipped'
        ($r | Where-Object Step -EQ 'RemoveLicenses').Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName M365UserLifecycle Set-Mailbox -Times 0 -Exactly
    }

    It 'changes nothing when the user cannot be found' {
        Mock -ModuleName M365UserLifecycle Get-MgUser -ParameterFilter { $UserId -eq 'jordan.doe@contoso.com' } { throw 'Resource does not exist' }
        $r = @(Invoke-MulLeaver -Path $script:LeaverCsv -Apply -Confirm:$false -ReportPath $script:Report -LogPath $script:Log -WarningAction SilentlyContinue)
        $r.Count | Should -Be 1
        $r[0].Status | Should -Be 'Failed'
        Should -Invoke -ModuleName M365UserLifecycle Update-MgUser -Times 0 -Exactly
    }

    It 'respects -SkipOneDriveHandoff' {
        $r = Invoke-MulLeaver -Path $script:LeaverCsv -Apply -Confirm:$false -SkipOneDriveHandoff -ReportPath $script:Report -LogPath $script:Log
        ($r | Where-Object Step -EQ 'OneDriveHandoff').Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName M365UserLifecycle Invoke-MgInviteDriveItem -Times 0 -Exactly
    }

    It 'requires an Exchange Online connection' {
        Mock -ModuleName M365UserLifecycle Get-Command -ParameterFilter { $Name -eq 'Set-Mailbox' } { $null }
        { Invoke-MulLeaver -Path $script:LeaverCsv -ReportPath $script:Report -LogPath $script:Log } | Should -Throw '*Connect-ExchangeOnline*'
    }
}

Describe 'Get-MulRandomPassword (private)' {
    It 'meets complexity rules and is unique per call' {
        InModuleScope M365UserLifecycle {
            $a = Get-MulRandomPassword
            $b = Get-MulRandomPassword
            $a.Length | Should -Be 24
            $a | Should -Match '[A-Z]'
            $a | Should -Match '[a-z]'
            $a | Should -Match '[0-9]'
            $a | Should -Match '[^A-Za-z0-9]'
            $a | Should -Not -Be $b
        }
    }
}
