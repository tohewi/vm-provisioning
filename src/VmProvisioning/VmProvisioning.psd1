@{
    RootModule           = 'VmProvisioning.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'b6f5c0a4-3f1e-4c55-9d3e-2a7f1d6c8e41'
    Author               = 'vm-provisioning'
    Description          = 'Helpers for provisioning AD / Entra ID joined Windows Server VMs on Azure without leaking secrets.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'New-LocalAdminPassword'
        'Set-LocalAdminPasswordSecret'
        'Get-VmLoginGroupName'
        'Initialize-EntraLoginGroup'
        'Read-DeploymentParameterFile'
        'Invoke-VmDeployment'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
