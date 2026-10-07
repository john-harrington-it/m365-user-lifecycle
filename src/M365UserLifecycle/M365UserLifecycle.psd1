@{
    RootModule           = 'M365UserLifecycle.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'e7a4c2d9-3b5f-4e1a-8c6d-9f0b1a2c3d44'
    Author               = 'John Harrington'
    Copyright            = '(c) John Harrington. MIT License.'
    Description          = 'CSV-driven Microsoft 365 joiner/leaver automation on the Microsoft Graph PowerShell SDK and Exchange Online, with dry-run by default, -WhatIf/-Confirm, idempotent re-runs, and a per-step audit report.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Import-MulJoinerCsv'
        'Import-MulLeaverCsv'
        'Invoke-MulJoiner'
        'Invoke-MulLeaver'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags                       = @('Microsoft365', 'MicrosoftGraph', 'EntraID', 'ExchangeOnline', 'Onboarding', 'Offboarding', 'Lifecycle')
            LicenseUri                 = 'https://opensource.org/licenses/MIT'
            ExternalModuleDependencies = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Users.Actions', 'Microsoft.Graph.Groups', 'Microsoft.Graph.Files', 'ExchangeOnlineManagement')
        }
    }
}
