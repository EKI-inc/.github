# Azure AI Account Key Rotation

Reusable runbook and helper scripts for rotating Azure AI / Cognitive Services account keys and updating corresponding Azure Key Vault secrets.

The scripts support Azure AI Services, Azure OpenAI, Azure AI Foundry-backed resources, Document Intelligence, and other Cognitive Services accounts that expose `Key1` and `Key2` through `az cognitiveservices account keys`.

## Files

- `discover_keyvault_mappings.ps1`: scans accessible Azure subscriptions for Azure AI/Cognitive Services account keys and candidate Key Vault secrets, then writes a manifest when a Key Vault secret value matches a current account key.
- `rotate_azure_ai_account_keys.ps1`: dry-run-first rotation helper that regenerates the matched key slot and updates the mapped Key Vault secrets.
- `key_rotation_manifest.example.csv`: placeholder manifest format.
- `.gitignore`: prevents live manifests, discovery logs, and result CSVs from being committed.

## Requirements

- Azure CLI installed and on `PATH`.
- `az login` completed for an account with:
  - `Microsoft.CognitiveServices/accounts/listKeys/action`
  - `Microsoft.CognitiveServices/accounts/regenerateKey/action`
  - Key Vault secret list/read/set permissions for the mapped vaults.
- PowerShell 5.1 or newer.

## Safety Rules

- Do not commit live manifests, discovery outputs, result CSVs, or secret values.
- Always run a dry run before `-Execute`.
- Do not rotate a row unless the Key Vault secret value matches `Key1` or `Key2`, unless you have independently confirmed the mapping.
- If more than one Key Vault secret points to the same account key slot, rotate that slot once and update every mapped secret to the same regenerated value. The rotation script groups rows this way automatically.

## Discovery

Run discovery to build a local manifest from accessible subscriptions and vaults:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\discover_keyvault_mappings.ps1
```

By default, discovery only checks enabled Key Vault secrets with names that look like API keys. To check every enabled secret name:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\discover_keyvault_mappings.ps1 -IncludeAllSecretNames
```

The generated `key_rotation_manifest.csv` is intentionally ignored by git. Review it before rotation and remove unrelated service keys if the change window is scoped to only certain resources.

## Dry Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\rotate_azure_ai_account_keys.ps1 `
    -ManifestPath .\key_rotation_manifest.csv
```

Expected dry-run result:

- No keys are regenerated.
- No Key Vault secrets are updated.
- Each intended row has `Status=DryRun`.
- `MatchedSlot` and `RotatedSlot` are populated.

## Execute

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\rotate_azure_ai_account_keys.ps1 `
    -ManifestPath .\key_rotation_manifest.csv `
    -Execute
```

The script writes a local `key_rotation_results_*.csv` file. Keep that file with the maintenance record, but do not commit it.

## Validate

Check Key Vault secret metadata after rotation without printing secret values:

```powershell
az keyvault secret show `
    --vault-name <key-vault-name> `
    --name <secret-name> `
    --query "{updated:attributes.updated, enabled:attributes.enabled, rotatedAtUtc:tags.rotatedAtUtc, rotatedBy:tags.rotatedBy}" `
    --output table
```

## User Notification

After rotation, tell affected users to rerun the repo-specific setup or secret refresh script that populates their local `.env` file from Key Vault.

Suggested language:

```text
The Azure AI / Document Intelligence API keys were rotated and the corresponding Azure Key Vault secrets were updated.

If you use a local .env file populated from Key Vault, rerun the repo-specific setup or secret refresh script before running workflows that call these services. Existing local .env values may fail because they contain the old API key.

The expected stale-key failure is a 401/authentication error similar to: "Access denied due to invalid subscription key or wrong API endpoint."

Please do not send API key values when reporting issues.
```
