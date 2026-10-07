<#
.SYNOPSIS
    Example: unattended leaver processing with certificate-based app-only authentication.

.DESCRIPTION
    Connects to Microsoft Graph and Exchange Online with an app registration and certificate
    (no stored passwords), runs a dry run, and only applies when -Apply is passed.

.PARAMETER CsvPath
    Leaver CSV.

.PARAMETER TenantId
    Entra ID tenant ID.

.PARAMETER AppId
    App registration (client) ID.

.PARAMETER CertificateThumbprint
    Certificate thumbprint in the local store.

.PARAMETER Organization
    Tenant's initial domain, for example contoso.onmicrosoft.com.

.PARAMETER Apply
    Apply changes instead of a dry run.

.EXAMPLE
    ./offboard-with-app-auth.ps1 -CsvPath .\leavers.csv -TenantId <id> -AppId <id> -CertificateThumbprint <thumb> -Organization contoso.onmicrosoft.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AppId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]+$')]
    [string]$CertificateThumbprint,

    [Parameter(Mandatory)]
    [ValidatePattern('\.onmicrosoft\.com$')]
    [string]$Organization,

    [switch]$Apply
)

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../src/M365UserLifecycle/M365UserLifecycle.psd1') -Force

Connect-MgGraph -TenantId $TenantId -ClientId $AppId -CertificateThumbprint $CertificateThumbprint -NoWelcome
Connect-ExchangeOnline -AppId $AppId -CertificateThumbprint $CertificateThumbprint -Organization $Organization -ShowBanner:$false
try {
    $results = Invoke-MulLeaver -Path $CsvPath -Apply:$Apply -Confirm:$false
    $results | Format-Table -Property UserPrincipalName, Step, Status, Message -AutoSize -Wrap
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
}
