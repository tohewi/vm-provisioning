---
applyTo: "**/*.ps1,**/*.psm1,**/*.psd1"
---

# PowerShell instructions

- Target PowerShell 7.2+ (`pwsh`) everywhere **except** `infra/scripts/*.ps1`, which run on the VM in
  Windows PowerShell 5.1 (no ternary, `??`, `&&`, `-Parallel`, or PS7-only cmdlets; lint enforces).
- Use approved verbs, `[CmdletBinding()]`, `SupportsShouldProcess` for state-changing functions,
  `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'` in scripts.
- Return objects; log with `Write-Information` (not `Write-Host`).
- Secrets: only `[securestring]`. Never `ConvertTo-SecureString -AsPlainText`, never
  `Get-AzKeyVaultSecret -AsPlainText`, never pass secrets on a command line or to `Write-*`,
  never `##vso[task.setvariable]` a credential. Set `$DebugPreference = 'SilentlyContinue'` and
  `-Debug:$false` around Key Vault calls. Dispose secure strings when done.
- Use Az PowerShell (Az.Accounts / Az.Resources / Az.KeyVault); the pipeline runs `AzurePowerShell@5` with `pwsh: true`.
- Export new module functions in both `VmProvisioning.psd1` and `VmProvisioning.psm1`.
- Tests: Pester 5 in `tests/`, mock Az cmdlets with `Mock -ModuleName VmProvisioning`; tests must
  not need Azure access. Run `./build.ps1`.
