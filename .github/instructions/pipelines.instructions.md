---
applyTo: "pipelines/**/*.yml,pipelines/**/*.yaml"
---

# Azure DevOps pipeline instructions

- Pipelines are Azure DevOps YAML (not GitHub Actions). Entry: `pipelines/azure-pipelines.yml`;
  per-environment stage: `pipelines/templates/deploy-stage.yml`.
- Keep the shape: `Validate` (runs `./build.ps1`, publishes `out` as artifact `drop`) →
  per environment a `Plan_<env>` stage (what-if, no environment) → `Deploy_<env>` stage with a
  `deployment` job bound to an Azure DevOps Environment (approvals/checks live there). Keep them
  in separate stages: ADO runs approvals before a stage starts, so a what-if in the same stage
  would run only after approval. Deploy stages never run for PRs; prod only from `main`.
- Authenticate only through service connections (workload identity federation). No secrets,
  passwords or keys as pipeline variables; `System.Debug` stays `false`.
- Free-text runtime parameters are passed to scripts through `env:` and validated in the script;
  never interpolate `${{ parameters.* }}` free text into `ScriptArguments` or inline scripts.
- Deployment logic belongs in PowerShell (`scripts/`, `src/`), not in YAML.
- `tests/SecretHygiene.Tests.ps1` checks these rules; extend it when you add new patterns.
