# Static guards that keep secrets out of code, logs and pipeline variables.
# If one of these fails, fix the code - do not weaken the test.

BeforeDiscovery {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:PsFiles = Get-ChildItem $repoRoot -Recurse -Include '*.ps1', '*.psm1' -File |
        Where-Object { $_.FullName -notmatch '[\\/](out|\.git)[\\/]' -and $_.FullName -notmatch '[\\/]tests[\\/]' } |
        ForEach-Object { @{ Name = $_.FullName.Substring($repoRoot.Length + 1); Path = $_.FullName } }
    $script:YamlFiles = Get-ChildItem (Join-Path $repoRoot 'pipelines') -Recurse -Include '*.yml', '*.yaml' -File |
        ForEach-Object { @{ Name = $_.FullName.Substring($repoRoot.Length + 1); Path = $_.FullName } }
}

Describe 'PowerShell secret handling: <Name>' -ForEach $PsFiles {
    BeforeAll {
        $script:Content = Get-Content $Path -Raw
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    }

    It 'does not convert plain text to SecureString' {
        $Content | Should -Not -Match 'ConvertTo-SecureString[^\r\n]*-AsPlainText'
    }

    It 'does not read Key Vault secrets as plain text' {
        $Content | Should -Not -Match 'Get-AzKeyVaultSecret[^\r\n]*-AsPlainText'
        $Content | Should -Not -Match 'az\s+keyvault\s+secret\s+(show|set)'
    }

    It 'does not set pipeline variables containing credentials' {
        $Content | Should -Not -Match '##vso\[task\.setvariable[^\]]*(password|secret|credential)'
    }

    It 'never passes password/secret variables to output cmdlets' {
        $writes = $Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -match '^(Write-(Host|Output|Information|Verbose|Debug|Warning)|Out-\w+|Add-Content|Set-Content)$'
            }, $true)
        foreach ($w in $writes) {
            $vars = $w.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
            $names = @(foreach ($v in $vars) { $v.VariablePath.UserPath })
            $names | Where-Object { $_ -match '^(\w*password|\w*secretvalue|pw|plain\w*)$' } |
                Should -BeNullOrEmpty -Because "line $($w.Extent.StartLineNumber): '$($w.Extent.Text)'"
        }
    }
}

Describe 'Pipeline hygiene: <Name>' -ForEach $YamlFiles {
    BeforeAll {
        $script:Content = Get-Content $Path -Raw
    }

    It 'does not enable System.Debug' {
        $Content | Should -Not -Match '(?ims)name:\s*system\.debug\s*\r?\n\s*value:\s*[''"]?true'
        $Content | Should -Not -Match '(?im)system\.debug\s*:\s*[''"]?true'
    }

    It 'does not declare secret-looking inline variables' {
        $Content | Should -Not -Match '(?im)^\s*-?\s*name:\s*\w*(password|secret|pwd)\w*\s*$'
        $Content | Should -Not -Match '(?im)^\s*\w*(password|pwd)\w*\s*:\s*\S+'
    }

    It 'does not interpolate free-text runtime parameters into scripts' {
        $Content | Should -Not -Match "ScriptArguments:[^\r\n]*\$\{\{\s*parameters\.vmFilter"
        $Content | Should -Not -Match "(?ms)ScriptArguments:\s*>-.*?-VmFilter\s+'\$\{\{"
    }
}

Describe 'Pipeline structure' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Main = Get-Content (Join-Path $root 'pipelines' 'azure-pipelines.yml') -Raw
        $script:Stage = Get-Content (Join-Path $root 'pipelines' 'templates' 'deploy-stage.yml') -Raw
    }

    It 'explicitly disables System.Debug' {
        $Main | Should -Match '(?ims)name:\s*System\.Debug\s*\r?\n\s*value:\s*false'
    }

    It 'validates before deploying and deploys prod only from main' {
        $Main | Should -Match 'stage:\s*Validate'
        $Main | Should -Match "refs/heads/main"
        $Main | Should -Match "ne\(variables\['Build.Reason'\], 'PullRequest'\)"
    }

    It 'gates deployments with an Azure DevOps environment after a what-if job' {
        $Stage | Should -Match 'deployment:\s*Deploy'
        $Stage | Should -Match 'environment:\s*\$\{\{\s*parameters\.adoEnvironment\s*\}\}'
        $Stage | Should -Match 'dependsOn:\s*Plan'
        $Stage | Should -Match '-Mode WhatIf'
    }
}

Describe 'VM-side script Set-AdLoginGroups.ps1' {
    BeforeAll {
        $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'infra' 'scripts' 'Set-AdLoginGroups.ps1'
        $errors = $null
        $script:VmAst = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        $script:ParseErrors = $errors
    }

    It 'parses without errors' {
        $ParseErrors | Should -BeNullOrEmpty
    }

    It 'only uses $DomainPassword to bind to the directory and to clear it' {
        $uses = $VmAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq 'DomainPassword'
            }, $true) | Where-Object { $_.Parent -isnot [System.Management.Automation.Language.ParameterAst] }
        foreach ($u in $uses) {
            $u.Extent.StartScriptPosition.Line | Should -Match 'DirectoryEntry\(|\$DomainPassword = \$null'
        }
    }
}
