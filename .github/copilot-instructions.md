# Copilot instructions

Follow [`AGENTS.md`](../AGENTS.md) — it is the single source of truth for layout, commands,
conventions and the non-negotiable security rules of this repository.

Essentials:

- Validate every change with `./build.ps1` (PSScriptAnalyzer, bicep lint/build, Pester). It must be green.
- Never put secret values in files, logs, pipeline variables or Bicep outputs. Secrets live in Key Vault
  and are read with `getSecret()`; they reach VMs only via `protectedSettings` / `protectedParameters`.
- Never weaken or delete tests to get green.
- Do not deploy to Azure, Entra ID or AD from an agent session.
- Requirements: `ralph/specs/vm-provisioning.md`. Backlog: `ralph/IMPLEMENTATION_PLAN.md`.
