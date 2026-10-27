# Spec: Windows Server VM provisioning

## Goal

Provision Windows Server VMs into Azure through a multi-stage Azure DevOps pipeline whose
source is a GitHub repository. Each VM is either **Active Directory domain joined** or
**Microsoft Entra ID joined**.

## Assumptions (outside the scope of this repo)

- An AD DS domain exists and a **delegated OU** exists into which a service account may join
  computers (and create groups, when AD login groups are created automatically).
- A Microsoft Entra ID tenant exists.
- A VNet/subnet exists. For AD join it has line of sight (DNS + ports) to domain controllers.
- A Key Vault per environment exists (RBAC mode, `enabledForTemplateDeployment = true`).

## Functional requirements

1. One `.bicepparam` file per VM in `infra/parameters/<environment>/`.
2. `joinType = 'ActiveDirectory'`: VM joins the domain into `domainJoinOuPath`.
   Groups `<prefix>-<VMNAME>-Admins` / `-Users` exist in AD (created in `adGroupsOuPath` when
   missing) and are members of the local *Administrators* / *Remote Desktop Users* groups.
3. `joinType = 'EntraID'`: VM joins Entra ID. Groups `<prefix>-<VMNAME>-Admins` / `-Users`
   exist in Entra ID (created when missing) and hold *Virtual Machine Administrator Login* /
   *Virtual Machine User Login* on the VM. Extra existing group object IDs can be added.
4. Pipeline: Validate (lint, build, unit tests) → per environment What-if → approval → Deploy.
   PRs only validate. Production deploys only from `main`.

## Security requirements

1. The local admin password is generated with a CSPRNG inside the deployment process, stored
   directly in Key Vault, and consumed by the template through `getSecret()`. It is never in a
   pipeline variable, command line, file, log or deployment output.
2. The domain join password lives only in Key Vault and reaches the VM only through
   extension `protectedSettings` / Run Command `protectedParameters`.
3. No secret values in the repository; tests guard against regressions.
4. No public IP on VMs. Trusted Launch (secure boot + vTPM) enabled.
5. Pipelines authenticate with workload identity federation service connections (no client secrets).

## Technology

- PowerShell 7 (pwsh) for all automation; Windows PowerShell 5.1 only for scripts executed on the VM.
- Bicep for all infrastructure.
- Pester 5 and PSScriptAnalyzer for tests and linting.
