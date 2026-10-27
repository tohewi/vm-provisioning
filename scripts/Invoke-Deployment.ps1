<#
.SYNOPSIS
    Pipeline entry point: what-if or deploy every VM parameter file of one environment.

.DESCRIPTION
    Runs inside an AzurePowerShell@5 task (pwsh) in Azure DevOps, or locally after
    Connect-AzAccount. Expects the build artifact produced by build.ps1:

        <ArtifactPath>/main.json                       compiled template
        <ArtifactPath>/parameters/<env>/<vm>.json      compiled parameter files
        <ArtifactPath>/src/VmProvisioning              PowerShell module

    No secret is ever passed to or returned from this script.

.EXAMPLE
    ./scripts/Invoke-Deployment.ps1 -Environment dev -ResourceGroupName rg-vm-dev -Location westeurope -Mode WhatIf
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9-]+$')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$Location,

    [ValidateSet('WhatIf', 'Deploy')]
    [string]$Mode = 'WhatIf',

    [string]$ArtifactPath = (Join-Path $PSScriptRoot '..' 'out'),

    # Wildcard filter on VM parameter file names (without extension).
    [ValidatePattern('^[A-Za-z0-9*?_-]{1,64}$')]
    [string]$VmFilter = '*'
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$DebugPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

if ($env:SYSTEM_DEBUG -eq 'true') {
    Write-Warning 'System.Debug is enabled. This tooling suppresses Az debug tracing, but avoid System.Debug on deployment pipelines.'
}

$modulePath = @(
    (Join-Path $ArtifactPath 'src' 'VmProvisioning')
    (Join-Path $PSScriptRoot '..' 'src' 'VmProvisioning')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
Import-Module $modulePath -Force

$templateFile = Join-Path $ArtifactPath 'main.json'
$parameterDir = Join-Path $ArtifactPath 'parameters' $Environment
if (-not (Test-Path $templateFile)) { throw "Compiled template not found: $templateFile. Run ./build.ps1 -Task Build." }
if (-not (Test-Path $parameterDir)) { throw "No parameter directory for environment '$Environment': $parameterDir" }

$files = @(Get-ChildItem -Path $parameterDir -Filter '*.json' | Where-Object { $_.BaseName -like $VmFilter } | Sort-Object Name)
if ($files.Count -eq 0) {
    Write-Warning "No VM parameter files matched '$VmFilter' in $parameterDir. Nothing to do."
    return
}

# What-if requires the resource group to exist, so it is ensured in both modes.
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    Write-Information "Creating resource group '$ResourceGroupName' in '$Location'."
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{ environment = $Environment; managedBy = 'vm-provisioning' } | Out-Null
}

$results = foreach ($file in $files) {
    Write-Information "===== $Mode $($file.BaseName) ====="
    $result = Invoke-VmDeployment -ResourceGroupName $ResourceGroupName -TemplateFile $templateFile `
        -ParameterFile $file.FullName -Mode $Mode
    if ($Mode -eq 'WhatIf') {
        Write-Information $result.Changes
    }
    $result
}

$results | Select-Object -Property * -ExcludeProperty Changes | Format-Table -AutoSize | Out-String -Width 300 | Write-Information
