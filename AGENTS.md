# AGENTS.md

Guidelines for AI coding agents (GitHub Copilot coding agent, Copilot CLI, Ralph loops) and
humans working in this repository. Read this before changing anything.

## What this repo does

Provisions Windows Server VMs into Azure that are **AD domain joined** (into a delegated OU)
or **Microsoft Entra ID joined**, with login groups, via a multi-stage **Azure DevOps** pipeline
whose source is this **GitHub** repo. Requirements: `ralph/specs/vm-provisioning.md`.

## Layout

| Path | Purpose |
| --- | --- |
| `infra/main.bicep` | Entry template (resource group scope). Reads secrets from Key Vault with `getSecret()`. |
| `infra/modules/*.bicep` | `windowsVm`, `activeDirectory` (AD-only wrapper that reads the join secret and calls `domainJoin` + `adLoginGroups` Run Command), `entraJoin` (+ RBAC). |
| `infra/scripts/*.ps1` | Scripts that run **on the VM** (Windows PowerShell 5.1), embedded with `loadTextContent()`. |
| `infra/parameters/<env>/<vm>.bicepparam` | One file per VM. No secrets. |
| `src/VmProvisioning/` | PowerShell 7 module used by the pipeline. |
| `scripts/` | Entry-point scripts (`Invoke-Deployment.ps1`, `Set-DomainJoinSecret.ps1`). |
| `pipelines/` | Azure DevOps YAML (`azure-pipelines.yml`, `templates/deploy-stage.yml`). |
| `tests/` | Pester 5 tests (unit, compiled-template assertions, secret hygiene, Ralph loop). |
| `ralph/` | Ralph loop runner, prompt, implementation plan and specs. |
| `build.ps1` | The only build/lint/test entry point. |

## Commands

```powershell
./build.ps1                 # Lint + Build + Test (what CI runs). Must be green before you finish.
./build.ps1 -Task Lint      # PSScriptAnalyzer (warnings fail) + bicep lint (errors fail)
./build.ps1 -Task Build     # bicep build / build-params -> ./out (pipeline artifact)
./build.ps1 -Task Test      # Pester -> ./out/test-results.xml
./build.ps1 -Task Bootstrap # install Pester / PSScriptAnalyzer, locate Bicep CLI
```

Tools: PowerShell 7.2+, Bicep CLI (or Azure CLI which installs it), Pester ≥ 5.5, PSScriptAnalyzer.
`./build.ps1` takes ~1 minute. Never deploy to Azure from an agent session; there are no credentials.

## Security rules (non-negotiable)

1. **No secret values in the repo**: no passwords, keys, tokens, connection strings, real tenant
   or subscription IDs. Use `00000000-0000-0000-0000-000000000000` placeholders.
2. **Secrets never travel through the pipeline.** The local admin password is created by
   `Set-LocalAdminPasswordSecret` directly in Key Vault as a `[securestring]`; templates read
   secrets with `keyVault.getSecret()` into `@secure()` module parameters.
3. Secrets reach VMs only via extension `protectedSettings` or Run Command `protectedParameters`.
4. Never: `ConvertTo-SecureString -AsPlainText`, `Get-AzKeyVaultSecret -AsPlainText`,
   `az keyvault secret show/set`, `##vso[task.setvariable]` for credentials, `System.Debug: true`,
   `Write-*` of password variables, secrets in Bicep outputs, `commandToExecute` with secrets.
5. Free-text pipeline parameters go to scripts via `env:` and are validated, never interpolated
   into `ScriptArguments` / `inlineScript`.
6. Functions that touch Key Vault force `$DebugPreference = 'SilentlyContinue'` (Az debug tracing
   prints HTTP bodies).

`tests/SecretHygiene.Tests.ps1` and `tests/Bicep.Tests.ps1` enforce these. **Never weaken, skip or
delete a test to make the build pass**; fix the code instead.

## Conventions

- PowerShell 7 for everything that runs on the agent; approved verbs; `[CmdletBinding()]`;
  `SupportsShouldProcess` for state-changing functions; `Set-StrictMode -Version Latest`;
  `$ErrorActionPreference = 'Stop'` in scripts. Return objects, log with `Write-Information`.
- Scripts under `infra/scripts/` run on the VM: **Windows PowerShell 5.1 syntax only** (lint enforces),
  no external modules, address built-in groups by well-known SID.
- Bicep: one concern per module, `@description` on every parameter, `@secure()` for secrets,
  explicit API versions that pass `use-recent-api-versions`, no hard-coded environment URLs.
  `bicepconfig.json` turns security linter rules into errors.
- Login group naming `<prefix>-<VMNAME>-Admins|Users` is implemented in both `infra/main.bicep`
  and `Get-VmLoginGroupName`; a test keeps them in sync.
- New VM = new `infra/parameters/<env>/<vmname>.bicepparam` (VM name ≤ 15 chars). No code change.
- Every behaviour change ships with Pester tests. Mock Az cmdlets with
  `Mock -ModuleName VmProvisioning`; tests must run without Azure access.
- Update `README.md` when prerequisites, permissions or pipeline behaviour change.

## Definition of done

- `./build.ps1` is green.
- Tests cover the change; no test was weakened.
- Docs updated; `ralph/IMPLEMENTATION_PLAN.md` updated if you worked a plan item.

## Ralph loop

`ralph/Invoke-RalphLoop.ps1` feeds `ralph/PROMPT.md` to an agent CLI repeatedly, using
`./build.ps1` as back-pressure, until `ralph/IMPLEMENTATION_PLAN.md` has no open items.
Run it on a feature branch: `./ralph/Invoke-RalphLoop.ps1 -MaxIterations 5`. See README.

## Operational learnings

<!-- One line each. Only durable facts about building/testing this repo. -->
- `build.ps1` sets strict mode, which propagates into Pester tests: guard member access on possibly-empty collections.
- Compiled `main.json` uses `languageVersion 2.0` (resources is a map); nested module templates use resource arrays.
