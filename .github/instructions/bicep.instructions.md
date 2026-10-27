---
applyTo: "**/*.bicep,**/*.bicepparam,bicepconfig.json"
---

# Bicep instructions

- Templates live in `infra/`; one concern per module in `infra/modules/`.
- Every `param` has `@description`. Secrets are `@secure()` and only ever filled from
  `keyVault.getSecret('<name>')` on an `existing` vault (in `infra/main.bicep`, or for mode-specific
  secrets inside the mode-specific module such as `activeDirectory.bicep`, so a conditional deployment
  never references a secret it does not use) — never from a parameter file.
- Pass secrets to VMs only through extension `protectedSettings` or Run Command `protectedParameters`.
  Never put a secret in `settings`, `parameters`, `commandToExecute`, tags or outputs.
- Parameters that hold Key Vault *names* of secrets end with `SecretName`; no other parameter
  name may contain `password` or `secret` (enforced by `tests/Bicep.Tests.ps1`).
- `.bicepparam` files: one VM per file under `infra/parameters/<env>/`, `using '../../main.bicep'`,
  VM name ≤ 15 characters, placeholder IDs only (`00000000-0000-0000-0000-000000000000`).
- No public IPs, keep Trusted Launch. Use API versions accepted by `use-recent-api-versions`.
- Scripts embedded with `loadTextContent()` must be Windows PowerShell 5.1 compatible.
- After changes run `./build.ps1`; add assertions on the compiled JSON in `tests/Bicep.Tests.ps1`
  for new security-relevant behaviour.
