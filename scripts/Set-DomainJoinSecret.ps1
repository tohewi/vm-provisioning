<#
.SYNOPSIS
    One-time helper for an administrator to store the domain join account password in Key Vault.

.DESCRIPTION
    Prompts for the password as a SecureString (never echoed, never on the command line,
    never in shell history) and stores it in Key Vault. Run it interactively after
    Connect-AzAccount with an identity that has "Key Vault Secrets Officer" on the vault.

.EXAMPLE
    ./scripts/Set-DomainJoinSecret.ps1 -VaultName kv-vmprov-dev
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{2,23}$')]
    [string]$VaultName,

    [ValidatePattern('^[a-zA-Z0-9-]{1,127}$')]
    [string]$SecretName = 'domain-join-password',

    # Optional expiry to force periodic rotation of the domain join account password.
    [datetime]$Expires
)

$ErrorActionPreference = 'Stop'
$DebugPreference = 'SilentlyContinue'

$password = Read-Host -Prompt "Password for the domain join account (stored as '$SecretName' in '$VaultName')" -AsSecureString
try {
    if ($password.Length -eq 0) { throw 'Empty password.' }
    if ($PSCmdlet.ShouldProcess("$VaultName/$SecretName", 'Store domain join password')) {
        $splat = @{
            VaultName   = $VaultName
            Name        = $SecretName
            SecretValue = $password
            ContentType = 'domain-join-password'
            ErrorAction = 'Stop'
        }
        if ($PSBoundParameters.ContainsKey('Expires')) { $splat.Expires = $Expires.ToUniversalTime() }
        $result = Set-AzKeyVaultSecret @splat -Debug:$false
        Write-Information "Stored secret '$SecretName' (version $($result.Version)) in '$VaultName'." -InformationAction Continue
    }
}
finally {
    $password.Dispose()
}
