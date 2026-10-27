# Implementation plan

Prioritised backlog for the Ralph loop (`ralph/Invoke-RalphLoop.ps1`) and for Copilot coding
agent tasks. One item per iteration / PR. Keep items small and testable.
Format: `- [ ] <item> — <why / acceptance hint>`.

## Done (baseline)

- [x] Bicep: Windows Server VM (Trusted Launch, private NIC, system-assigned identity).
- [x] Bicep: AD domain join into delegated OU (JsonADDomainExtension, protectedSettings).
- [x] Bicep: AD login groups created in delegated OU and added to local groups (managed Run Command, protectedParameters).
- [x] Bicep: Entra ID join (AADLoginForWindows) + VM Administrator/User Login role assignments to groups.
- [x] PowerShell: local admin password generated into Key Vault, never logged.
- [x] PowerShell: Entra login groups ensured via Az.Resources (Microsoft Graph).
- [x] Azure DevOps: Validate → What-if → approval-gated Deploy per environment.
- [x] Agent guidelines, path-scoped Copilot instructions, Copilot setup steps, Ralph loop.

## Backlog

- [ ] Data disks: optional `dataDisks` array parameter (size, SKU, caching, LUN) in `windowsVm.bicep` — tests assert deleteOption and LUN uniqueness.
- [ ] Windows LAPS for AD-joined VMs: document GPO/Intune configuration in `docs/` and add an optional Run Command that enables Windows LAPS backup to AD — rotate the Key Vault bootstrap password out of use.
- [ ] Azure Monitor Agent + Data Collection Rule association (optional parameter `dataCollectionRuleId`) — Bicep test asserts the extension and association exist only when set.
- [ ] Azure Backup: optional protection of the VM in an existing Recovery Services vault (`backupPolicyId`).
- [ ] Optional cleanup of the `Set-AdLoginGroups` Run Command after success (parameter `removeRunCommandAfterSuccess`) — limits how long its status output stays in the VM instance view.
- [ ] `scripts/Remove-Vm.ps1`: decommission flow (delete VM, remove computer object guidance, delete Entra groups and Key Vault secret with soft-delete) with `-WhatIf` support and unit tests.
