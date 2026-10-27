BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent

    # Stubs so the tests also run where the Az modules are not installed.
    # Pester mocks replace them; they only need to exist with compatible parameters.
    $stubs = @{
        'Get-AzKeyVaultSecret'                     = 'param($VaultName, $Name)'
        'Set-AzKeyVaultSecret'                     = 'param($VaultName, $Name, [securestring]$SecretValue, $ContentType, [hashtable]$Tag)'
        'Get-AzADGroup'                            = 'param($DisplayName)'
        'New-AzADGroup'                            = 'param($DisplayName, $MailNickname, [switch]$SecurityEnabled, $Description)'
        'Get-AzResourceGroupDeploymentWhatIfResult' = 'param($Name, $ResourceGroupName, $TemplateFile, [hashtable]$TemplateParameterObject, [switch]$SkipTemplateParameterPrompt)'
        'New-AzResourceGroupDeployment'            = 'param($Name, $ResourceGroupName, $TemplateFile, [hashtable]$TemplateParameterObject, [switch]$SkipTemplateParameterPrompt)'
    }
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("[CmdletBinding()] $($stubs[$name]) throw 'stub: $name must be mocked'"))
        }
    }

    Import-Module (Join-Path $repoRoot 'src' 'VmProvisioning') -Force

    function ConvertTo-PlainTextForTest([securestring]$Value) {
        [System.Net.NetworkCredential]::new('', $Value).Password
    }

    function Write-TestParameterFile {
        param([hashtable]$Values)
        $parameters = @{}
        foreach ($k in $Values.Keys) { $parameters[$k] = @{ value = $Values[$k] } }
        $path = Join-Path $TestDrive "$([guid]::NewGuid()).json"
        @{ '$schema' = 'x'; contentVersion = '1.0.0.0'; parameters = $parameters } | ConvertTo-Json -Depth 10 | Set-Content $path
        $path
    }
}

Describe 'New-LocalAdminPassword' {
    It 'returns a read-only SecureString of the requested length' {
        $pw = New-LocalAdminPassword -Length 32
        $pw | Should -BeOfType [securestring]
        $pw.IsReadOnly() | Should -BeTrue
        $pw.Length | Should -Be 32
    }

    It 'contains upper, lower, digit and symbol characters' {
        1..25 | ForEach-Object {
            $plain = ConvertTo-PlainTextForTest (New-LocalAdminPassword -Length 16)
            $plain | Should -MatchExactly '[A-Z]'
            $plain | Should -MatchExactly '[a-z]'
            $plain | Should -Match '[0-9]'
            $plain | Should -Match '[^A-Za-z0-9]'
        }
    }

    It 'never contains characters that are unsafe in shells, JSON or XML' {
        1..25 | ForEach-Object {
            ConvertTo-PlainTextForTest (New-LocalAdminPassword) | Should -Not -Match '["''`$&<>\\;\s]'
        }
    }

    It 'generates unique values' {
        $values = 1..50 | ForEach-Object { ConvertTo-PlainTextForTest (New-LocalAdminPassword) }
        ($values | Select-Object -Unique).Count | Should -Be 50
    }

    It 'rejects lengths below 16' {
        { New-LocalAdminPassword -Length 12 } | Should -Throw
    }
}

Describe 'Set-LocalAdminPasswordSecret' {
    It 'leaves an existing secret untouched' {
        Mock -ModuleName VmProvisioning Get-AzKeyVaultSecret { [pscustomobject]@{ Version = 'v1' } }
        Mock -ModuleName VmProvisioning Set-AzKeyVaultSecret { }

        $r = Set-LocalAdminPasswordSecret -VaultName 'kv-test' -SecretName 'vm01-localadmin'

        $r.Action | Should -Be 'Unchanged'
        $r.Version | Should -Be 'v1'
        Should -Invoke -ModuleName VmProvisioning Set-AzKeyVaultSecret -Times 0
    }

    It 'creates a secret with a SecureString value and never emits the value' {
        Mock -ModuleName VmProvisioning Get-AzKeyVaultSecret { $null }
        Mock -ModuleName VmProvisioning Set-AzKeyVaultSecret {
            $script:CapturedPlain = [System.Net.NetworkCredential]::new('', $SecretValue).Password
            [pscustomobject]@{ Version = 'v2' }
        }

        $allStreams = Set-LocalAdminPasswordSecret -VaultName 'kv-test' -SecretName 'vm01-localadmin' -Verbose *>&1
        $r = $allStreams | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Action'] }

        $r.Action | Should -Be 'Created'
        $r.Version | Should -Be 'v2'
        $r.PSObject.Properties.Name | Should -Not -Contain 'SecretValue'
        Should -Invoke -ModuleName VmProvisioning Set-AzKeyVaultSecret -Times 1 -ParameterFilter {
            $SecretValue -is [securestring] -and $ContentType -eq 'local-admin-password'
        }
        $captured = $script:CapturedPlain
        $captured | Should -Not -BeNullOrEmpty
        ($allStreams | Out-String) | Should -Not -Match ([regex]::Escape($captured))
    }

    It 'does not create anything with -WhatIf' {
        Mock -ModuleName VmProvisioning Get-AzKeyVaultSecret { $null }
        Mock -ModuleName VmProvisioning Set-AzKeyVaultSecret { }

        (Set-LocalAdminPasswordSecret -VaultName 'kv-test' -SecretName 'vm01-localadmin' -WhatIf).Action | Should -Be 'WouldCreate'
        Should -Invoke -ModuleName VmProvisioning Set-AzKeyVaultSecret -Times 0
    }

    It 'propagates Key Vault read errors instead of overwriting the secret' {
        Mock -ModuleName VmProvisioning Get-AzKeyVaultSecret { throw 'Forbidden' }
        Mock -ModuleName VmProvisioning Set-AzKeyVaultSecret { }

        { Set-LocalAdminPasswordSecret -VaultName 'kv-test' -SecretName 'vm01-localadmin' } | Should -Throw '*Forbidden*'
        Should -Invoke -ModuleName VmProvisioning Set-AzKeyVaultSecret -Times 0
    }
}

Describe 'Get-VmLoginGroupName' {
    It 'builds PREFIX-VMNAME-Admins / -Users' {
        $n = Get-VmLoginGroupName -VmName 'vmdevapp01'
        $n.Admin | Should -BeExactly 'SRV-VMDEVAPP01-Admins'
        $n.User | Should -BeExactly 'SRV-VMDEVAPP01-Users'
        (Get-VmLoginGroupName -VmName 'vm1' -Prefix 'GRP-AZ').Admin | Should -BeExactly 'GRP-AZ-VM1-Admins'
    }

    It 'rejects VM names longer than 15 characters' {
        { Get-VmLoginGroupName -VmName 'abcdefghijklmnop' } | Should -Throw
    }
}

Describe 'Initialize-EntraLoginGroup' {
    It 'returns an existing group' {
        Mock -ModuleName VmProvisioning Get-AzADGroup { [pscustomobject]@{ Id = 'id-1' } }
        Mock -ModuleName VmProvisioning New-AzADGroup { }

        $r = Initialize-EntraLoginGroup -DisplayName 'SRV-VM1-Admins'
        $r.ObjectId | Should -Be 'id-1'
        $r.Action | Should -Be 'Existing'
        Should -Invoke -ModuleName VmProvisioning New-AzADGroup -Times 0
    }

    It 'creates a missing security group' {
        Mock -ModuleName VmProvisioning Get-AzADGroup { }
        Mock -ModuleName VmProvisioning New-AzADGroup { [pscustomobject]@{ Id = 'id-new' } }

        $r = Initialize-EntraLoginGroup -DisplayName 'SRV-VM1-Admins' -Description 'd'
        $r.ObjectId | Should -Be 'id-new'
        $r.Action | Should -Be 'Created'
        Should -Invoke -ModuleName VmProvisioning New-AzADGroup -Times 1 -ParameterFilter {
            $SecurityEnabled -and $DisplayName -eq 'SRV-VM1-Admins' -and $MailNickname -eq 'SRV-VM1-Admins'
        }
    }

    It 'throws when the display name is ambiguous' {
        Mock -ModuleName VmProvisioning Get-AzADGroup { [pscustomobject]@{ Id = 'a' }; [pscustomobject]@{ Id = 'b' } }
        { Initialize-EntraLoginGroup -DisplayName 'SRV-VM1-Admins' } | Should -Throw '*Multiple*'
    }

    It 'does not create with -WhatIf' {
        Mock -ModuleName VmProvisioning Get-AzADGroup { }
        Mock -ModuleName VmProvisioning New-AzADGroup { }

        (Initialize-EntraLoginGroup -DisplayName 'SRV-VM1-Admins' -WhatIf).Action | Should -Be 'WouldCreate'
        Should -Invoke -ModuleName VmProvisioning New-AzADGroup -Times 0
    }
}

Describe 'Read-DeploymentParameterFile' {
    It 'returns parameter values as a hashtable' {
        $p = Read-DeploymentParameterFile -Path (Write-TestParameterFile @{ vmName = 'vm1'; tags = @{ a = 'b' } })
        $p.vmName | Should -Be 'vm1'
        $p.tags.a | Should -Be 'b'
    }

    It 'rejects Key Vault references' {
        $path = Join-Path $TestDrive 'ref.json'
        '{"parameters":{"pw":{"reference":{"keyVault":{"id":"x"},"secretName":"y"}}}}' | Set-Content $path
        { Read-DeploymentParameterFile -Path $path } | Should -Throw '*getSecret*'
    }
}

Describe 'Invoke-VmDeployment' {
    BeforeAll {
        $script:Template = Join-Path $TestDrive 'main.json'
        '{}' | Set-Content $Template
    }

    BeforeEach {
        Mock -ModuleName VmProvisioning Get-AzKeyVaultSecret { [pscustomobject]@{ Version = 'v1' } }
        Mock -ModuleName VmProvisioning Set-AzKeyVaultSecret { }
        Mock -ModuleName VmProvisioning Get-AzADGroup { }
        Mock -ModuleName VmProvisioning New-AzADGroup { [pscustomobject]@{ Id = "id-$DisplayName" } }
        Mock -ModuleName VmProvisioning Get-AzResourceGroupDeploymentWhatIfResult { [pscustomobject]@{ Status = 'Succeeded' } }
        Mock -ModuleName VmProvisioning New-AzResourceGroupDeployment {
            [pscustomobject]@{
                ProvisioningState = 'Succeeded'
                Outputs           = @{
                    vmResourceId     = [pscustomobject]@{ Value = '/subscriptions/x/vm' }
                    privateIpAddress = [pscustomobject]@{ Value = '10.0.0.4' }
                }
            }
        }
    }

    Context 'EntraID' {
        BeforeAll {
            $script:EntraFile = Write-TestParameterFile @{
                vmName = 'vmweb01'; joinType = 'EntraID'; keyVaultName = 'kv-test'
                entraAdminGroupObjectIds = @('existing-admin')
            }
        }

        It 'creates the Entra login groups and passes their IDs to the deployment' {
            $r = Invoke-VmDeployment -ResourceGroupName 'rg' -TemplateFile $Template -ParameterFile $EntraFile -Mode Deploy

            $r.Status | Should -Be 'Succeeded'
            $r.AdminGroupName | Should -Be 'SRV-VMWEB01-Admins'
            $r.LocalAdminSecretName | Should -Be 'vmweb01-localadmin'
            Should -Invoke -ModuleName VmProvisioning New-AzADGroup -Times 2
            Should -Invoke -ModuleName VmProvisioning New-AzResourceGroupDeployment -Times 1 -ParameterFilter {
                $TemplateParameterObject.entraAdminGroupObjectIds -contains 'existing-admin' -and
                $TemplateParameterObject.entraAdminGroupObjectIds -contains 'id-SRV-VMWEB01-Admins' -and
                $TemplateParameterObject.entraUserGroupObjectIds -contains 'id-SRV-VMWEB01-Users' -and
                $TemplateParameterObject.localAdminPasswordSecretName -eq 'vmweb01-localadmin' -and
                $Name -like 'vm-vmweb01-*'
            }
        }

        It 'does not create groups or deploy in WhatIf mode' {
            $r = Invoke-VmDeployment -ResourceGroupName 'rg' -TemplateFile $Template -ParameterFile $EntraFile -Mode WhatIf

            $r.Mode | Should -Be 'WhatIf'
            Should -Invoke -ModuleName VmProvisioning New-AzADGroup -Times 0
            Should -Invoke -ModuleName VmProvisioning New-AzResourceGroupDeployment -Times 0
            Should -Invoke -ModuleName VmProvisioning Get-AzResourceGroupDeploymentWhatIfResult -Times 1 -ParameterFilter {
                @($TemplateParameterObject.entraAdminGroupObjectIds) -contains 'existing-admin'
            }
        }
    }

    Context 'ActiveDirectory' {
        It 'requires the domain parameters' {
            $file = Write-TestParameterFile @{ vmName = 'vmapp01'; joinType = 'ActiveDirectory'; keyVaultName = 'kv-test' }
            { Invoke-VmDeployment -ResourceGroupName 'rg' -TemplateFile $Template -ParameterFile $file } | Should -Throw '*domainFqdn*'
        }

        It 'fails fast when the domain join secret is missing' {
            Mock -ModuleName VmProvisioning Get-AzKeyVaultSecret { $null } -ParameterFilter { $Name -eq 'domain-join-password' }
            $file = Write-TestParameterFile @{
                vmName = 'vmapp01'; joinType = 'ActiveDirectory'; keyVaultName = 'kv-test'
                domainFqdn = 'corp.contoso.com'; domainJoinOuPath = 'OU=S,DC=corp,DC=contoso,DC=com'; domainJoinUserName = 'svc@corp.contoso.com'
            }
            { Invoke-VmDeployment -ResourceGroupName 'rg' -TemplateFile $Template -ParameterFile $file -Mode Deploy } |
                Should -Throw "*domain-join-password*"
            Should -Invoke -ModuleName VmProvisioning New-AzResourceGroupDeployment -Times 0
        }

        It 'deploys without touching Entra ID' {
            $file = Write-TestParameterFile @{
                vmName = 'vmapp01'; joinType = 'ActiveDirectory'; keyVaultName = 'kv-test'
                domainFqdn = 'corp.contoso.com'; domainJoinOuPath = 'OU=S,DC=corp,DC=contoso,DC=com'; domainJoinUserName = 'svc@corp.contoso.com'
            }
            (Invoke-VmDeployment -ResourceGroupName 'rg' -TemplateFile $Template -ParameterFile $file -Mode Deploy).Status | Should -Be 'Succeeded'
            Should -Invoke -ModuleName VmProvisioning Get-AzADGroup -Times 0
            Should -Invoke -ModuleName VmProvisioning New-AzResourceGroupDeployment -Times 1 -ParameterFilter {
                $TemplateParameterObject.adminGroupName -eq 'SRV-VMAPP01-Admins'
            }
        }
    }

    It 'rejects parameter files without a Key Vault' {
        $file = Write-TestParameterFile @{ vmName = 'vm1'; joinType = 'EntraID' }
        { Invoke-VmDeployment -ResourceGroupName 'rg' -TemplateFile $Template -ParameterFile $file } | Should -Throw '*keyVaultName*'
    }
}
