<#
.SYNOPSIS
    Single entry point for local development, the Copilot agent, Ralph loops and CI.

.DESCRIPTION
    Tasks:
      Bootstrap  Install Pester / PSScriptAnalyzer if missing and locate the Bicep CLI.
      Lint       PSScriptAnalyzer (errors + warnings fail) and `bicep lint` (errors fail).
      Build      Compile infra/main.bicep and every infra/parameters/<env>/*.bicepparam to ./out,
                 and copy the PowerShell module + scripts so ./out is a self-contained artifact.
      Test       Pester (results in ./out/test-results.xml, NUnit format).
      All        Lint, Build, Test (default).

.EXAMPLE
    ./build.ps1
    ./build.ps1 -Task Test
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OutputPath', Justification = 'Consumed by nested task functions.')]
[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'Lint', 'Build', 'Test', 'All')]
    [string[]]$Task = 'All',

    [string]$OutputPath = (Join-Path $PSScriptRoot 'out')
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Set-StrictMode -Version Latest

$repoRoot = $PSScriptRoot
$infraPath = Join-Path $repoRoot 'infra'

function Get-BicepPath {
    $cmd = Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    $azBicep = Join-Path $HOME '.azure' 'bin' 'bicep'
    if ($IsWindows) { $azBicep += '.exe' }
    if (-not (Test-Path $azBicep) -and (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Information 'Bicep CLI not found on PATH; installing via az bicep install.'
        & az bicep install --only-show-errors | Out-Null
    }
    if (Test-Path $azBicep) { return $azBicep }
    throw 'Bicep CLI not found. Install it (https://aka.ms/bicep-install) or install the Azure CLI.'
}

function Invoke-Bicep {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    & $script:Bicep @Arguments
    if ($LASTEXITCODE -ne 0) { throw "bicep $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
}

function Invoke-Bootstrap {
    foreach ($m in @(@{ Name = 'Pester'; Version = '5.5.0' }, @{ Name = 'PSScriptAnalyzer'; Version = '1.22.0' })) {
        $installed = Get-Module -ListAvailable -Name $m.Name | Where-Object { $_.Version -ge [version]$m.Version }
        if (-not $installed) {
            Write-Information "Installing $($m.Name) >= $($m.Version)"
            Install-Module -Name $m.Name -MinimumVersion $m.Version -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
        }
    }
    $script:Bicep = Get-BicepPath
    Write-Information "Bicep: $script:Bicep"
}

function Invoke-Lint {
    Write-Information '== PSScriptAnalyzer =='
    $findings = @(
        Invoke-ScriptAnalyzer -Path $repoRoot -Recurse -Settings (Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1')
        # Scripts in infra/scripts run ON the VM in Windows PowerShell 5.1.
        Invoke-ScriptAnalyzer -Path (Join-Path $infraPath 'scripts') -Recurse -Settings @{
            IncludeRules = @('PSUseCompatibleSyntax')
            Rules        = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } }
        }
    ) | Where-Object { $_ -and $_.ScriptPath -notlike (Join-Path $OutputPath '*') }
    if ($findings) {
        $findings | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String -Width 300 | Write-Information
        throw "PSScriptAnalyzer reported $(@($findings).Count) finding(s)."
    }

    Write-Information '== bicep lint =='
    Invoke-Bicep lint (Join-Path $infraPath 'main.bicep')
    Get-ChildItem (Join-Path $infraPath 'parameters') -Recurse -Filter '*.bicepparam' | ForEach-Object {
        Invoke-Bicep lint $_.FullName
    }
}

function Invoke-Build {
    Write-Information "== Build -> $OutputPath =="
    if (Test-Path $OutputPath) { Remove-Item $OutputPath -Recurse -Force }
    New-Item -ItemType Directory -Path $OutputPath | Out-Null

    Invoke-Bicep build (Join-Path $infraPath 'main.bicep') --outfile (Join-Path $OutputPath 'main.json')

    Get-ChildItem (Join-Path $infraPath 'parameters') -Recurse -Filter '*.bicepparam' | ForEach-Object {
        $envName = $_.Directory.Name
        $target = Join-Path $OutputPath 'parameters' $envName
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Invoke-Bicep build-params $_.FullName --outfile (Join-Path $target "$($_.BaseName).json")
    }

    Copy-Item (Join-Path $repoRoot 'src') (Join-Path $OutputPath 'src') -Recurse
    Copy-Item (Join-Path $repoRoot 'scripts') (Join-Path $OutputPath 'scripts') -Recurse
}

function Invoke-Test {
    Write-Information '== Pester =='
    Import-Module Pester -MinimumVersion 5.5.0
    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $repoRoot 'tests'
    $config.Run.Exit = $false
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    $config.TestResult.OutputPath = Join-Path $OutputPath 'test-results.xml'
    $result = Invoke-Pester -Configuration $config
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
        throw "Pester: $($result.FailedCount) test(s) failed."
    }
}

Invoke-Bootstrap
$steps = if ($Task -contains 'All') { 'Lint', 'Build', 'Test' } else { $Task | Where-Object { $_ -ne 'Bootstrap' } }
foreach ($step in $steps) {
    & "Invoke-$step"
}
Write-Information "build.ps1: $($steps -join ', ') succeeded."
