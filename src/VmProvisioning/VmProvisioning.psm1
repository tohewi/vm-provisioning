#Requires -Version 7.2
Set-StrictMode -Version Latest

<#
    VmProvisioning module

    SECURITY RULES (enforced by tests in tests/SecretHygiene.Tests.ps1):
    * Secrets only ever exist as [securestring] in this module and are never written to
      any output stream, pipeline variable, file or command line.
    * Functions that talk to Key Vault force $DebugPreference = 'SilentlyContinue' so that
      Az HTTP debug tracing (which includes request bodies) can never print a secret.
#>

$script:UpperChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
$script:LowerChars = 'abcdefghijkmnopqrstuvwxyz'
$script:DigitChars = '23456789'
# Deliberately excludes quotes, backtick, $, &, <, >, \, ; and whitespace to stay safe
# in any shell, JSON, XML or RDP context.
$script:SymbolChars = '!#%*+-=?@_~'

function New-LocalAdminPassword {
    <#
    .SYNOPSIS
        Generates a cryptographically random password that satisfies Azure / Windows
        complexity rules and returns it as a read-only [securestring].
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure function; does not change system state.')]
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [ValidateRange(16, 123)]
        [int]$Length = 24
    )

    $rng = [System.Security.Cryptography.RandomNumberGenerator]
    $sets = @($script:UpperChars, $script:LowerChars, $script:DigitChars, $script:SymbolChars)
    $all = -join $sets
    $chars = [char[]]::new($Length)
    try {
        # Guarantee at least one character from every class.
        for ($i = 0; $i -lt $sets.Count; $i++) {
            $chars[$i] = $sets[$i][$rng::GetInt32($sets[$i].Length)]
        }
        for ($i = $sets.Count; $i -lt $Length; $i++) {
            $chars[$i] = $all[$rng::GetInt32($all.Length)]
        }
        # Fisher-Yates shuffle so the guaranteed characters are not at fixed positions.
        for ($i = $Length - 1; $i -gt 0; $i--) {
            $j = $rng::GetInt32($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }

        $secure = [securestring]::new()
        foreach ($c in $chars) { $secure.AppendChar($c) }
        $secure.MakeReadOnly()
        return $secure
    }
    finally {
        [Array]::Clear($chars, 0, $chars.Length)
    }
}

function Set-LocalAdminPasswordSecret {
    <#
    .SYNOPSIS
        Ensures a Key Vault secret with a random local admin password exists.
    .DESCRIPTION
        Idempotent: an existing secret is left untouched (the Azure VM API does not allow the
        admin password of an existing VM to be changed through a redeployment). Rotate the
        password after deployment with Windows LAPS or the VMAccess extension instead.
        The password value is never returned or logged; only metadata is returned.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{2,23}$')]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z0-9-]{1,127}$')]
        [string]$SecretName,

        [hashtable]$Tag = @{}
    )

    $DebugPreference = 'SilentlyContinue'

    $existing = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -ErrorAction Stop -Debug:$false
    if ($null -ne $existing) {
        return [pscustomobject]@{
            VaultName  = $VaultName
            SecretName = $SecretName
            Action     = 'Unchanged'
            Version    = $existing.Version
        }
    }

    if (-not $PSCmdlet.ShouldProcess("$VaultName/$SecretName", 'Create local admin password secret')) {
        return [pscustomobject]@{
            VaultName  = $VaultName
            SecretName = $SecretName
            Action     = 'WouldCreate'
            Version    = $null
        }
    }

    $password = New-LocalAdminPassword
    try {
        $result = Set-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -SecretValue $password `
            -ContentType 'local-admin-password' -Tag $Tag -ErrorAction Stop -Debug:$false
    }
    finally {
        $password.Dispose()
    }

    return [pscustomobject]@{
        VaultName  = $VaultName
        SecretName = $SecretName
        Action     = 'Created'
        Version    = $result.Version
    }
}

function Get-VmLoginGroupName {
    <#
    .SYNOPSIS
        Returns the login group names for a VM: <Prefix>-<VMNAME>-Admins / -Users.
        Must stay in sync with the defaults of adminGroupName / userGroupName in infra/main.bicep.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
        [string]$VmName,

        [ValidatePattern('^[A-Za-z0-9-]{1,20}$')]
        [string]$Prefix = 'SRV'
    )

    $upper = $VmName.ToUpperInvariant()
    [pscustomobject]@{
        Admin = "$Prefix-$upper-Admins"
        User  = "$Prefix-$upper-Users"
    }
}

function Initialize-EntraLoginGroup {
    <#
    .SYNOPSIS
        Returns the object ID of an Entra ID security group, creating it if it does not exist.
    .NOTES
        The deployment identity needs the Microsoft Graph application permission Group.Create
        (to create) and Group.Read.All (to look up) or an equivalent Entra role.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
        [string]$DisplayName,

        [string]$Description = ''
    )

    $groups = @(Get-AzADGroup -DisplayName $DisplayName -ErrorAction Stop)
    if ($groups.Count -gt 1) {
        throw "Multiple Entra groups named '$DisplayName' exist. Resolve the ambiguity or pass object IDs explicitly."
    }
    if ($groups.Count -eq 1) {
        return [pscustomobject]@{ DisplayName = $DisplayName; ObjectId = $groups[0].Id; Action = 'Existing' }
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create Entra ID security group')) {
        return [pscustomobject]@{ DisplayName = $DisplayName; ObjectId = $null; Action = 'WouldCreate' }
    }

    $mailNickname = $DisplayName -replace '[^A-Za-z0-9._-]', ''
    $group = New-AzADGroup -DisplayName $DisplayName -MailNickname $mailNickname -SecurityEnabled `
        -Description $Description -ErrorAction Stop
    return [pscustomobject]@{ DisplayName = $DisplayName; ObjectId = $group.Id; Action = 'Created' }
}

function Read-DeploymentParameterFile {
    <#
    .SYNOPSIS
        Reads a compiled ARM parameter file (output of `bicep build-params`) into a hashtable
        suitable for -TemplateParameterObject.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Path
    )

    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $json.ContainsKey('parameters')) {
        throw "'$Path' is not an ARM deployment parameter file."
    }

    $result = @{}
    foreach ($name in $json.parameters.Keys) {
        $entry = $json.parameters[$name]
        if ($entry.ContainsKey('reference')) {
            throw "Parameter '$name' in '$Path' uses a Key Vault reference. Secrets must be read in the template with getSecret()."
        }
        $result[$name] = $entry['value']
    }
    return $result
}

function Get-OptionalValue {
    param([hashtable]$Table, [string]$Key, $Default)
    if ($Table.ContainsKey($Key) -and -not [string]::IsNullOrEmpty([string]$Table[$Key])) {
        return $Table[$Key]
    }
    return $Default
}

function Invoke-VmDeployment {
    <#
    .SYNOPSIS
        Deploys (or what-ifs) one VM described by a compiled parameter file.
    .DESCRIPTION
        1. Validates the parameters for the selected join type.
        2. Ensures the local admin password secret exists in Key Vault (also in WhatIf mode,
           because ARM resolves Key Vault references during what-if).
        3. For Entra ID join: ensures the Entra login groups exist (not created in WhatIf mode).
        4. Runs the deployment or what-if with the compiled ARM template.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$TemplateFile,

        [Parameter(Mandatory)]
        [string]$ParameterFile,

        [ValidateSet('WhatIf', 'Deploy')]
        [string]$Mode = 'WhatIf',

        [string]$DeploymentNameSuffix = (Get-Date -Format 'yyyyMMddHHmmss')
    )

    $DebugPreference = 'SilentlyContinue'
    $isWhatIf = $Mode -eq 'WhatIf'

    $params = Read-DeploymentParameterFile -Path $ParameterFile
    foreach ($required in 'vmName', 'joinType', 'keyVaultName') {
        if ([string]::IsNullOrEmpty([string](Get-OptionalValue $params $required ''))) {
            throw "Parameter '$required' is required in '$ParameterFile'."
        }
    }

    $vmName = [string]$params.vmName
    $joinType = [string]$params.joinType
    $vaultName = [string]$params.keyVaultName

    $names = Get-VmLoginGroupName -VmName $vmName -Prefix (Get-OptionalValue $params 'loginGroupPrefix' 'SRV')
    $params.adminGroupName = Get-OptionalValue $params 'adminGroupName' $names.Admin
    $params.userGroupName = Get-OptionalValue $params 'userGroupName' $names.User
    $params.localAdminPasswordSecretName = Get-OptionalValue $params 'localAdminPasswordSecretName' "$vmName-localadmin"

    switch ($joinType) {
        'ActiveDirectory' {
            foreach ($required in 'domainFqdn', 'domainJoinOuPath', 'domainJoinUserName') {
                if ([string]::IsNullOrEmpty([string](Get-OptionalValue $params $required ''))) {
                    throw "Parameter '$required' is required for joinType 'ActiveDirectory' ($ParameterFile)."
                }
            }
            $djSecret = Get-OptionalValue $params 'domainJoinPasswordSecretName' 'domain-join-password'
            $exists = Get-AzKeyVaultSecret -VaultName $vaultName -Name $djSecret -ErrorAction Stop -Debug:$false
            if ($null -eq $exists) {
                throw "Domain join secret '$djSecret' was not found in Key Vault '$vaultName'. Upload it before deploying."
            }
        }
        'EntraID' { }
        default { throw "Unsupported joinType '$joinType'." }
    }

    $secret = Set-LocalAdminPasswordSecret -VaultName $vaultName -SecretName $params.localAdminPasswordSecretName `
        -Tag @{ vmName = $vmName; purpose = 'local-admin' } -WhatIf:$false
    Write-Information "[$vmName] Local admin secret '$($secret.SecretName)': $($secret.Action)."

    if ($joinType -eq 'EntraID') {
        $admin = Initialize-EntraLoginGroup -DisplayName $params.adminGroupName `
            -Description "Administrator login to Azure VM $vmName" -WhatIf:$isWhatIf
        $user = Initialize-EntraLoginGroup -DisplayName $params.userGroupName `
            -Description "User login to Azure VM $vmName" -WhatIf:$isWhatIf
        foreach ($g in $admin, $user) {
            Write-Information "[$vmName] Entra group '$($g.DisplayName)': $($g.Action)."
        }
        $params.entraAdminGroupObjectIds = @(@(Get-OptionalValue $params 'entraAdminGroupObjectIds' @()) + $admin.ObjectId |
                Where-Object { $_ } | Select-Object -Unique)
        $params.entraUserGroupObjectIds = @(@(Get-OptionalValue $params 'entraUserGroupObjectIds' @()) + $user.ObjectId |
                Where-Object { $_ } | Select-Object -Unique)
    }

    $deploymentName = "vm-$vmName-$DeploymentNameSuffix"
    if ($deploymentName.Length -gt 64) { $deploymentName = $deploymentName.Substring(0, 64) }

    $common = @{
        Name                    = $deploymentName
        ResourceGroupName       = $ResourceGroupName
        TemplateFile            = $TemplateFile
        TemplateParameterObject = $params
        SkipTemplateParameterPrompt = $true
        ErrorAction             = 'Stop'
    }

    if ($isWhatIf) {
        $whatIf = Get-AzResourceGroupDeploymentWhatIfResult @common
        return [pscustomobject]@{
            VmName   = $vmName
            JoinType = $joinType
            Mode     = $Mode
            Status   = $whatIf.Status
            Changes  = ($whatIf | Out-String)
        }
    }

    $deployment = New-AzResourceGroupDeployment @common
    if ($deployment.ProvisioningState -ne 'Succeeded') {
        throw "Deployment '$deploymentName' finished with state '$($deployment.ProvisioningState)'."
    }

    return [pscustomobject]@{
        VmName               = $vmName
        JoinType             = $joinType
        Mode                 = $Mode
        Status               = $deployment.ProvisioningState
        VmResourceId         = $deployment.Outputs['vmResourceId'].Value
        PrivateIpAddress     = $deployment.Outputs['privateIpAddress'].Value
        AdminGroupName       = $params.adminGroupName
        UserGroupName        = $params.userGroupName
        LocalAdminSecretName = $params.localAdminPasswordSecretName
    }
}

Export-ModuleMember -Function New-LocalAdminPassword, Set-LocalAdminPasswordSecret, Get-VmLoginGroupName,
Initialize-EntraLoginGroup, Read-DeploymentParameterFile, Invoke-VmDeployment
