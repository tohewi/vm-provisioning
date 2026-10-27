BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:InfraPath = Join-Path $RepoRoot 'infra'

    $script:Bicep = (Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $Bicep) {
        $candidate = Join-Path $HOME '.azure' 'bin' 'bicep'
        if ($IsWindows) { $candidate += '.exe' }
        if (Test-Path $candidate) { $script:Bicep = $candidate }
    }
    if (-not $Bicep) { throw 'Bicep CLI not found. Run ./build.ps1 -Task Bootstrap.' }

    $json = & $Bicep build (Join-Path $InfraPath 'main.bicep') --stdout 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'main.bicep failed to compile.' }
    $script:Template = ($json -join "`n") | ConvertFrom-Json -AsHashtable

    function Get-TemplateResource {
        param($Deployment, [string]$Type)
        $nested = $Deployment.properties.template.resources
        $items = if ($nested -is [System.Collections.IDictionary]) { $nested.Values } else { $nested }
        @($items | Where-Object { $_.type -eq $Type })
    }

    function Get-NestedResource {
        param([string]$Module, [string]$Type)
        Get-TemplateResource -Deployment $script:Template.resources[$Module] -Type $Type
    }

    # Inner deployments of the AD wrapper module, keyed by the module file they deploy.
    $adInner = Get-NestedResource -Module 'activeDirectory' -Type 'Microsoft.Resources/deployments'
    $script:AdDomainJoin = $adInner | Where-Object { $_.properties.parameters.ContainsKey('domainJoinPassword') }
    $script:AdLoginGroups = $adInner | Where-Object { $_.properties.parameters.ContainsKey('domainPassword') }
}

Describe 'main.bicep' {
    It 'declares no parameter that carries a secret value (only secret names)' {
        $suspicious = $Template.parameters.Keys | Where-Object { $_ -match 'password|secret' -and $_ -notmatch 'SecretName$' }
        $suspicious | Should -BeNullOrEmpty
    }

    It 'has no securestring parameters at the top level' {
        $Template.parameters.Values | Where-Object { $_.type -in 'securestring', 'secureObject' } | Should -BeNullOrEmpty
    }

    It 'does not output anything secret' {
        foreach ($name in $Template.outputs.Keys) {
            $Template.outputs[$name].type | Should -Not -Be 'securestring'
            ($Template.outputs[$name] | ConvertTo-Json -Depth 20) | Should -Not -Match 'listKeys|getSecret|reference\(.*keyVault'
        }
    }

    It 'passes the local admin password as a Key Vault reference into a securestring parameter' {
        $Template.resources.vm.properties.parameters.adminPassword.reference.keyVault | Should -Not -BeNullOrEmpty
        $Template.resources.vm.properties.template.parameters.adminPassword.type | Should -Be 'securestring'
    }

    It 'passes the domain join password as a Key Vault reference inside the AD-only module' {
        $AdDomainJoin.properties.parameters.domainJoinPassword.reference.keyVault | Should -Not -BeNullOrEmpty
        $AdLoginGroups.properties.parameters.domainPassword.reference.keyVault | Should -Not -BeNullOrEmpty
    }

    It 'references the domain join secret only from the AD module (Entra deployments never resolve it)' {
        foreach ($name in $Template.resources.Keys | Where-Object { $_ -ne 'activeDirectory' }) {
            ($Template.resources[$name] | ConvertTo-Json -Depth 50) | Should -Not -Match 'domainJoinPasswordSecretName' -Because $name
        }
        $Template.resources.activeDirectory.properties.parameters.domainJoinPasswordSecretName | Should -Not -BeNullOrEmpty
    }

    It 'only deploys AD resources for ActiveDirectory and Entra resources for EntraID' {
        $Template.resources.activeDirectory.condition | Should -Match 'ActiveDirectory'
        $Template.resources.entraJoin.condition | Should -Match 'EntraID'
    }

    It 'keeps the login group naming convention in sync with Get-VmLoginGroupName' {
        $Template.parameters.adminGroupName.defaultValue | Should -Be "[format('{0}-{1}-Admins', parameters('loginGroupPrefix'), toUpper(parameters('vmName')))]"
        $Template.parameters.userGroupName.defaultValue | Should -Be "[format('{0}-{1}-Users', parameters('loginGroupPrefix'), toUpper(parameters('vmName')))]"
        $Template.parameters.loginGroupPrefix.defaultValue | Should -Be 'SRV'
    }
}

Describe 'windowsVm module' {
    BeforeAll {
        $script:Vm = Get-NestedResource -Module 'vm' -Type 'Microsoft.Compute/virtualMachines'
        $script:Nic = Get-NestedResource -Module 'vm' -Type 'Microsoft.Network/networkInterfaces'
    }

    It 'uses Trusted Launch with secure boot and vTPM' {
        $Vm.properties.securityProfile.securityType | Should -Be 'TrustedLaunch'
        $Vm.properties.securityProfile.uefiSettings.secureBootEnabled | Should -BeTrue
        $Vm.properties.securityProfile.uefiSettings.vTpmEnabled | Should -BeTrue
    }

    It 'has a system-assigned identity (required for Entra join)' {
        $Vm.identity.type | Should -Be 'SystemAssigned'
    }

    It 'does not create a public IP' {
        $Nic.properties.ipConfigurations[0].properties.Keys | Should -Not -Contain 'publicIPAddress'
        Get-NestedResource -Module 'vm' -Type 'Microsoft.Network/publicIPAddresses' | Should -BeNullOrEmpty
    }
}

Describe 'domainJoin module' {
    It 'creates login groups only after the domain join' {
        $AdLoginGroups.dependsOn | Should -Not -BeNullOrEmpty
    }

    It 'sends the password only in protectedSettings' {
        $ext = Get-TemplateResource -Deployment $AdDomainJoin -Type 'Microsoft.Compute/virtualMachines/extensions'
        $ext.properties.type | Should -Be 'JsonADDomainExtension'
        $ext.properties.protectedSettings.Password | Should -Not -BeNullOrEmpty
        $ext.properties.settings.Keys | Should -Not -Contain 'Password'
        $ext.properties.settings.OUPath | Should -Not -BeNullOrEmpty
    }
}

Describe 'adLoginGroups module' {
    BeforeAll {
        $script:RunCommand = Get-TemplateResource -Deployment $AdLoginGroups -Type 'Microsoft.Compute/virtualMachines/runCommands'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $InfraPath 'scripts' 'Set-AdLoginGroups.ps1'), [ref]$null, [ref]$null)
        $script:ScriptParams = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
    }

    It 'sends the domain password only as a protected parameter' {
        $RunCommand.properties.protectedParameters.name | Should -Be @('DomainPassword')
        $RunCommand.properties.parameters.name | Should -Not -Contain 'DomainPassword'
    }

    It 'fails the deployment when the script fails' {
        $RunCommand.properties.treatFailureAsDeploymentFailure | Should -BeTrue
        $RunCommand.properties.asyncExecution | Should -BeFalse
    }

    It 'only passes parameters that the VM script declares' {
        $names = @($RunCommand.properties.parameters.name) + @($RunCommand.properties.protectedParameters.name)
        foreach ($n in $names) { $ScriptParams | Should -Contain $n }
    }
}

Describe 'entraJoin module' {
    It 'installs AADLoginForWindows' {
        $ext = Get-NestedResource -Module 'entraJoin' -Type 'Microsoft.Compute/virtualMachines/extensions'
        $ext.properties.publisher | Should -Be 'Microsoft.Azure.ActiveDirectory'
        $ext.properties.type | Should -Be 'AADLoginForWindows'
    }

    It 'grants the VM Administrator Login and VM User Login roles to groups' {
        $assignments = Get-NestedResource -Module 'entraJoin' -Type 'Microsoft.Authorization/roleAssignments'
        $vars = $Template.resources.entraJoin.properties.template.variables
        $vars.vmAdminLoginRoleId | Should -Be '1c0163c0-47e6-4577-8991-ea5c82e286e4'
        $vars.vmUserLoginRoleId | Should -Be 'fb879df8-f326-4884-b1cf-06f3ad86be52'
        $assignments.properties.roleDefinitionId | Should -Match 'vmAdminLoginRoleId|vmUserLoginRoleId'
        $assignments.properties.principalType | Should -Not -Contain 'User'
    }
}

Describe 'parameter files' {
    $files = Get-ChildItem (Join-Path (Split-Path $PSScriptRoot -Parent) 'infra' 'parameters') -Recurse -Filter '*.bicepparam' |
        ForEach-Object { @{ Name = "$($_.Directory.Name)/$($_.Name)"; Path = $_.FullName } }

    It '<Name> compiles' -TestCases $files {
        param($Path)
        $out = & $Bicep build-params $Path --stdout 2>$null
        $LASTEXITCODE | Should -Be 0
        $out | Should -Not -BeNullOrEmpty
    }

    It '<Name> contains no secret values' -TestCases $files {
        param($Path)
        $content = Get-Content $Path -Raw
        $content | Should -Not -Match '(?im)^\s*param\s+\w*(password|secret)\s*='
        $content | Should -Not -Match 'getSecret\('
    }

    It '<Name> uses a VM name of at most 15 characters' -TestCases $files {
        param($Path)
        $out = & $Bicep build-params $Path --stdout 2>$null
        $params = ((($out -join "`n") | ConvertFrom-Json).parametersJson | ConvertFrom-Json -AsHashtable).parameters
        $params.vmName.value.Length | Should -BeLessOrEqual 15
        $params.joinType.value | Should -BeIn 'ActiveDirectory', 'EntraID'
        $params.keyVaultName.value | Should -Not -BeNullOrEmpty
    }
}
