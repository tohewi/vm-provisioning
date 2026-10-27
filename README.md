# vm-provisioning

Provision **Active Directory domain-joined** or **Microsoft Entra ID-joined** Windows Server VMs
into Azure with **Bicep** and **PowerShell 7**, deployed by a multi-stage **Azure DevOps** pipeline
that builds from this **GitHub** repository — so the solution can be developed with the GitHub
Copilot coding agent (and Ralph loops) while deployments stay in Azure DevOps.

```
GitHub repo ──(Azure Pipelines GitHub App)──► Azure DevOps pipeline
                                               │
  Validate: PSScriptAnalyzer, bicep lint/build, Pester  ──► artifact "drop"
                                               │
  Deploy_dev:  What-if job ──► [approval on environment] ──► Deploy job
  Deploy_prod: What-if job ──► [approval on environment] ──► Deploy job   (main only)
                                               │
                    per VM (.bicepparam):      ▼
  1. Local admin password generated in-process ──► Key Vault secret <vm>-localadmin
  2. Entra ID join only: ensure Entra groups SRV-<VM>-Admins / -Users
  3. ARM deployment of main.json (template reads secrets with getSecret())
       ├─ VM (Trusted Launch, no public IP, system-assigned identity)
       ├─ AD:    JsonADDomainExtension → delegated OU
       │         Run Command → ensure AD groups in OU, add to local Administrators / RDP users
       └─ Entra: AADLoginForWindows → VM Administrator / User Login roles for the groups
```

## Contents

| Path | What |
| --- | --- |
| `infra/` | Bicep: `main.bicep`, `modules/`, VM-side script, `parameters/<env>/<vm>.bicepparam` |
| `src/VmProvisioning/` | PowerShell 7 module (password → Key Vault, Entra groups, deployment) |
| `scripts/` | `Invoke-Deployment.ps1` (pipeline entry), `Set-DomainJoinSecret.ps1` (admin helper) |
| `pipelines/` | Azure DevOps multi-stage YAML |
| `tests/` | Pester tests (unit, compiled-template security assertions, secret hygiene, Ralph loop) |
| `AGENTS.md`, `.github/` | Agent guidelines, Copilot instructions, Copilot setup steps |
| `ralph/` | Ralph loop runner, prompt, plan and specs |

## Prerequisites (per environment)

These are assumed to exist; this repository does not create them.

1. **Active Directory** (for `joinType = 'ActiveDirectory'`)
   * A **delegated OU** for computer objects, e.g. `OU=Servers,OU=Azure,DC=corp,DC=contoso,DC=com`.
   * A **domain join account** with *Create/Delete Computer objects* (and the usual
     reset-password/validated-write permissions) on that OU.
   * If AD login groups should be created automatically (`createAdLoginGroups = true`, default),
     the same account needs *Create Group objects* on `adGroupsOuPath` (defaults to the computer OU).
     Otherwise pre-create the groups and set `createAdLoginGroups = false`.
2. **Microsoft Entra ID** tenant (for `joinType = 'EntraID'`).
3. **Network**: an existing subnet. For AD join it must resolve and reach the domain controllers
   (VNet DNS pointing to AD DNS). For Entra join it needs outbound HTTPS to Entra endpoints.
4. **Key Vault** (RBAC authorization, soft delete + purge protection):
   * `enabledForTemplateDeployment = true` (required for `getSecret()`).
   * Secret `domain-join-password` (name configurable) with the domain join account's password.
     Store it interactively without it touching a command line or history:
     ```powershell
     Connect-AzAccount
     ./scripts/Set-DomainJoinSecret.ps1 -VaultName kv-vmprov-dev
     ```

### Permissions of the pipeline identity (service connection)

| Scope | Role / permission | Why |
| --- | --- | --- |
| Target resource group (or subscription if it should create the RG) | **Contributor** | VM, NIC, extensions, Run Command |
| Subnet | `Microsoft.Network/virtualNetworks/subnets/join/action` (e.g. *Network Contributor*) | attach NIC |
| Target resource group (Entra join only) | **Role Based Access Control Administrator**, ideally with a condition limiting it to *Virtual Machine Administrator Login* / *Virtual Machine User Login* | role assignments for login groups |
| Key Vault | **Key Vault Secrets Officer** | create `<vm>-localadmin`, check domain join secret exists |
| Key Vault | `Microsoft.KeyVault/vaults/deploy/action` (e.g. *Key Vault Contributor* or a custom role) | `getSecret()` during deployment |
| Microsoft Graph (application permissions, Entra join only) | **Group.Create**, **Group.Read.All** | look up / create `SRV-<VM>-Admins` / `-Users` |

## Azure DevOps setup (GitHub repository)

1. **Create the pipeline from GitHub**: Azure DevOps → *Pipelines* → *New pipeline* → *GitHub (YAML)*
   → authorize/install the **Azure Pipelines GitHub App** for this repo → *Existing Azure Pipelines YAML
   file* → `/pipelines/azure-pipelines.yml`. The GitHub App reports PR validation back to GitHub as a check.
2. **Service connections**: create Azure Resource Manager service connections using **workload identity
   federation** (no client secret) named `sc-vmprov-dev` and `sc-vmprov-prod`, and grant the permissions above.
   Add a *Branch control* check on `sc-vmprov-prod` allowing only `refs/heads/main`.
3. **Environments**: create `vm-provisioning-dev` and `vm-provisioning-prod`; add **Approvals** (at least on
   prod). Approvers review the *What-if* job log of the same stage before approving.
4. **Adjust** service connection names, resource groups and regions in `pipelines/azure-pipelines.yml`.
5. **GitHub branch protection** on `main`: require the Azure Pipelines check, require PR reviews.

Run-time parameters: `vmFilter` (wildcard on parameter file names, e.g. `vmdevapp*`) and `deployProd`.

## Adding a VM

Create `infra/parameters/<env>/<vmname>.bicepparam` (VM name ≤ 15 characters) — see the examples:

* `dev/vmdevapp01.bicepparam` — AD join into a delegated OU
* `dev/vmdevweb01.bicepparam` — Entra ID join
* `prod/vmprdapp01.bicepparam` — AD join, zone, Azure Hybrid Benefit, separate groups OU

Open a PR. The pipeline validates it; after merge it what-ifs and (after approval) deploys.

## Login groups

| Join type | Groups (default `SRV-<VMNAME>-Admins` / `-Users`) | Effect |
| --- | --- | --- |
| Active Directory | AD global security groups, created in `adGroupsOuPath` if missing (Run Command on the VM, using the domain join account) | Members of local **Administrators** / **Remote Desktop Users** (by well-known SID) |
| Entra ID | Entra security groups, created by the pipeline if missing | **Virtual Machine Administrator Login** / **Virtual Machine User Login** on the VM; extra groups via `entraAdminGroupObjectIds` / `entraUserGroupObjectIds` |

Override names per VM with `adminGroupName` / `userGroupName`, or the prefix with `loginGroupPrefix`.

## Security model — how secrets stay out of logs

* **Local admin password**: generated with `RandomNumberGenerator` inside the deployment process
  (`New-LocalAdminPassword`), held only as a `SecureString`, written straight to Key Vault
  (`<vm>-localadmin`). The template reads it with `keyVault.getSecret()` into a `@secure()` parameter,
  so it is never a pipeline variable, never on a command line, never in deployment history or outputs.
  An existing secret is never overwritten (Azure does not allow changing the admin password of an
  existing VM by redeploying). Retrieve it only via Key Vault RBAC (break-glass).
* **Domain join password**: lives only in Key Vault. Reaches the VM only via the domain join extension's
  `protectedSettings` and the Run Command's `protectedParameters` (encrypted, never returned by the API).
  The VM-side script never prints it.
* **Pipeline**: `System.Debug` is pinned to `false`; Key Vault calls run with debug tracing suppressed;
  free-text runtime parameters are passed through environment variables and validated (no script injection).
* **Template hardening**: Trusted Launch (secure boot + vTPM), no public IP, linter security rules as errors.
* **Guard rails**: `tests/SecretHygiene.Tests.ps1` and `tests/Bicep.Tests.ps1` fail the build on
  regressions (plain-text secret conversions, secret outputs, secret-looking parameters, debug enabled, …).

**Recommended next step**: enable **Windows LAPS** (AD or Entra backed) so the bootstrap local admin
password is rotated after deployment (see `ralph/IMPLEMENTATION_PLAN.md`).

## Local development

```powershell
./build.ps1              # Lint + Build + Test — run before every commit
./build.ps1 -Task Test
```

Requires PowerShell 7.2+, Bicep CLI (or Azure CLI), Pester 5.5+, PSScriptAnalyzer (`./build.ps1 -Task Bootstrap`).
A manual deployment works the same as in the pipeline:

```powershell
Connect-AzAccount
./build.ps1 -Task Build
./scripts/Invoke-Deployment.ps1 -Environment dev -ResourceGroupName rg-vmprov-dev -Location westeurope -Mode WhatIf
```

## Working with GitHub Copilot

* **Copilot coding agent**: assign an issue to Copilot. It follows `AGENTS.md`,
  `.github/copilot-instructions.md` and the path-scoped `.github/instructions/*.instructions.md`.
  `.github/workflows/copilot-setup-steps.yml` installs Pester, PSScriptAnalyzer and Bicep so the agent
  can run `./build.ps1`. Agents never get Azure credentials; deployments happen only in Azure DevOps.
* **Ralph loop** (autonomous iterations with build back-pressure):
  ```powershell
  git switch -c feature/next-items
  ./ralph/Invoke-RalphLoop.ps1 -MaxIterations 5                       # GitHub Copilot CLI (default)
  ./ralph/Invoke-RalphLoop.ps1 -AgentCommand claude -AgentArguments '-p','{prompt}','--dangerously-skip-permissions'
  ```
  Each iteration sends `ralph/PROMPT.md` to the agent, runs `./build.ps1`, feeds failures into the next
  iteration, commits green iterations locally (never pushes; refuses to run on `main`) and stops when
  `ralph/IMPLEMENTATION_PLAN.md` has no open items. Transcripts go to `.ralph/` (git-ignored).
  Review the commits, then push and open a PR as usual.

## Notes and limitations

* A soft-deleted Key Vault secret with the same name blocks creation; recover or purge it first.
* Newly created AD groups may need to replicate; the VM-side script retries adding them to local groups.
* Newly created Entra groups are assigned with `principalType: Group` to avoid replication delays.
* Run Command output is kept in the VM instance view; it contains only status lines, no secrets.
