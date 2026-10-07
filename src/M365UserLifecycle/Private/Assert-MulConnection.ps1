function Assert-MulConnection {
    <#
    .SYNOPSIS
        Throws a helpful error when Microsoft Graph (and optionally Exchange Online) is not connected.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [switch]$RequireExchange
    )

    if (-not (Get-Command -Name 'Get-MgContext' -ErrorAction SilentlyContinue) -or -not (Get-MgContext)) {
        throw 'Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes User.ReadWrite.All, Group.ReadWrite.All, MailboxSettings.ReadWrite, Files.ReadWrite.All'
    }
    if ($RequireExchange -and -not (Get-Command -Name 'Set-Mailbox' -ErrorAction SilentlyContinue)) {
        throw 'Not connected to Exchange Online. Run: Connect-ExchangeOnline'
    }
    return $true
}
