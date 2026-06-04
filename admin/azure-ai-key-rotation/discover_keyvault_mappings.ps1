#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$DiscoveryPath,
    [string[]]$SubscriptionIds,
    [string]$SecretNamePattern = '(?i)(openai|aoai|azure[-_]?openai|foundry|llm|cognitive|api[-_]?key|apikey|key)',
    [switch]$IncludeAllSecretNames,
    [switch]$OverwriteManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    if ([string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
        (Get-Location).Path
    }
    else {
        Split-Path -Parent $MyInvocation.MyCommand.Path
    }
}
else {
    $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $scriptRoot 'key_rotation_manifest.csv'
}

if ([string]::IsNullOrWhiteSpace($DiscoveryPath)) {
    $DiscoveryPath = Join-Path $scriptRoot ("key_rotation_discovery_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

function Invoke-AzRaw {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = [string]::Join([Environment]::NewLine, @($output))

    if ($exitCode -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$text"
    }

    return $text
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $text = Invoke-AzRaw -Arguments @($Arguments + @('--only-show-errors', '--output', 'json'))
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $json = $text | ConvertFrom-Json
    if ($json -is [System.Array]) {
        foreach ($item in $json) {
            $item
        }
    }
    else {
        $json
    }
}

function Invoke-AzTsv {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    return (Invoke-AzRaw -Arguments @($Arguments + @('--only-show-errors', '--output', 'tsv'))).Trim()
}

function Invoke-AzNoOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    [void](Invoke-AzRaw -Arguments @($Arguments + @('--only-show-errors', '--output', 'none')))
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI 'az' was not found. Install Azure CLI before running this script."
}

try {
    [void](Invoke-AzJson -Arguments @('account', 'show'))
}
catch {
    throw "Azure CLI is not logged in or cannot read the current account. Run 'az login' first. $($_.Exception.Message)"
}

if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
    $subscriptionText = Invoke-AzTsv -Arguments @('account', 'list', '--query', "[?state=='Enabled'].id")
    $SubscriptionIds = @($subscriptionText -split "[`r`n]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

if ($SubscriptionIds.Count -eq 0) {
    throw 'No enabled Azure subscriptions were found.'
}

Write-Host "Scanning $($SubscriptionIds.Count) enabled subscription(s)."

$keyIndex = @{}
$accountsScanned = 0
$keyReadFailures = New-Object System.Collections.Generic.List[object]

foreach ($subscriptionId in $SubscriptionIds) {
    Invoke-AzNoOutput -Arguments @('account', 'set', '--subscription', $subscriptionId)

    $accounts = @(Invoke-AzJson -Arguments @(
        'cognitiveservices', 'account', 'list',
        '--query', "[].{resourceGroup:resourceGroup, accountName:name, kind:kind}"
    ))

    foreach ($account in $accounts) {
        $accountsScanned++
        $resourceGroup = [string]$account.resourceGroup
        $accountName = [string]$account.accountName
        $kind = [string]$account.kind

        try {
            $keys = Invoke-AzJson -Arguments @(
                'cognitiveservices', 'account', 'keys', 'list',
                '--name', $accountName,
                '--resource-group', $resourceGroup
            )

            $slots = @(
                @{ Name = 'Key1'; Value = [string]$keys.key1 },
                @{ Name = 'Key2'; Value = [string]$keys.key2 }
            )

            foreach ($slot in $slots) {
                if ([string]::IsNullOrWhiteSpace($slot.Value)) {
                    continue
                }

                if (-not $keyIndex.ContainsKey($slot.Value)) {
                    $keyIndex[$slot.Value] = New-Object System.Collections.Generic.List[object]
                }

                $keyIndex[$slot.Value].Add([pscustomobject]@{
                    subscriptionId = $subscriptionId
                    resourceGroup = $resourceGroup
                    accountName = $accountName
                    accountKind = $kind
                    matchedSlot = $slot.Name
                })
            }
        }
        catch {
            $keyReadFailures.Add([pscustomobject]@{
                subscriptionId = $subscriptionId
                resourceGroup = $resourceGroup
                accountName = $accountName
                accountKind = $kind
                message = $_.Exception.Message
            })
        }
    }
}

Write-Host "Read key metadata for $accountsScanned Azure AI/Cognitive Services account(s)."

$matchedRows = New-Object System.Collections.Generic.List[object]
$secretReadFailures = New-Object System.Collections.Generic.List[object]
$vaultsScanned = 0
$secretsChecked = 0

foreach ($subscriptionId in $SubscriptionIds) {
    Invoke-AzNoOutput -Arguments @('account', 'set', '--subscription', $subscriptionId)

    $vaults = @(Invoke-AzJson -Arguments @(
        'keyvault', 'list',
        '--query', "[].{keyVaultName:name, resourceGroup:resourceGroup}"
    ))

    foreach ($vault in $vaults) {
        $vaultsScanned++
        $keyVaultName = [string]$vault.keyVaultName
        $secrets = @()

        try {
            $secrets = @(Invoke-AzJson -Arguments @(
                'keyvault', 'secret', 'list',
                '--vault-name', $keyVaultName,
                '--query', "[?attributes.enabled].{secretName:name}"
            ))
        }
        catch {
            $secretReadFailures.Add([pscustomobject]@{
                subscriptionId = $subscriptionId
                keyVaultName = $keyVaultName
                secretName = ''
                message = $_.Exception.Message
            })
            continue
        }

        foreach ($secret in $secrets) {
            $secretName = [string]$secret.secretName
            if (-not $IncludeAllSecretNames -and $secretName -notmatch $SecretNamePattern) {
                continue
            }

            $secretsChecked++
            try {
                $secretValue = Invoke-AzTsv -Arguments @(
                    'keyvault', 'secret', 'show',
                    '--vault-name', $keyVaultName,
                    '--name', $secretName,
                    '--query', 'value'
                )

                if ($keyIndex.ContainsKey($secretValue)) {
                    foreach ($matchedKey in $keyIndex[$secretValue]) {
                        $matchedRows.Add([pscustomobject]@{
                            subscriptionId = $matchedKey.subscriptionId
                            resourceGroup = $matchedKey.resourceGroup
                            accountName = $matchedKey.accountName
                            keyVaultName = $keyVaultName
                            secretName = $secretName
                            owner = ''
                            matchedSlot = $matchedKey.matchedSlot
                            notes = "Discovered from Key Vault secret value match; accountKind=$($matchedKey.accountKind)"
                        })
                    }
                }
            }
            catch {
                $secretReadFailures.Add([pscustomobject]@{
                    subscriptionId = $subscriptionId
                    keyVaultName = $keyVaultName
                    secretName = $secretName
                    message = $_.Exception.Message
                })
            }
        }
    }
}

$uniqueMatches = @(
    $matchedRows |
        Sort-Object subscriptionId, resourceGroup, accountName, keyVaultName, secretName -Unique
)

$uniqueMatches | Export-Csv -LiteralPath $DiscoveryPath -NoTypeInformation

if ($OverwriteManifest -or -not (Test-Path -LiteralPath $ManifestPath)) {
    $uniqueMatches | Export-Csv -LiteralPath $ManifestPath -NoTypeInformation
    Write-Host "Manifest written to: $ManifestPath"
}
else {
    Write-Host "Manifest already exists; discovery written only."
}

if ($keyReadFailures.Count -gt 0) {
    $failurePath = [System.IO.Path]::ChangeExtension($DiscoveryPath, '.key_read_failures.csv')
    $keyReadFailures | Export-Csv -LiteralPath $failurePath -NoTypeInformation
    Write-Warning "Some account keys could not be read. Failure CSV written to: $failurePath"
}

if ($secretReadFailures.Count -gt 0) {
    $failurePath = [System.IO.Path]::ChangeExtension($DiscoveryPath, '.secret_read_failures.csv')
    $secretReadFailures | Export-Csv -LiteralPath $failurePath -NoTypeInformation
    Write-Warning "Some Key Vault secrets could not be read. Failure CSV written to: $failurePath"
}

Write-Host "Vaults scanned: $vaultsScanned"
Write-Host "Candidate secrets checked: $secretsChecked"
Write-Host "Matched Key Vault secret(s): $($uniqueMatches.Count)"
Write-Host "Discovery CSV written to: $DiscoveryPath"
