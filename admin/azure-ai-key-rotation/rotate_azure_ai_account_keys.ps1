#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ManifestPath,

    [ValidateSet('Auto', 'Key1', 'Key2')]
    [string]$KeySlot = 'Auto',

    [switch]$Execute,
    [switch]$AllowUnmatchedSecret,
    [switch]$SkipLoginCheck,

    [string]$ResultPath
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

if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path $scriptRoot ("key_rotation_results_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
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

    $fullArgs = @($Arguments + @('--only-show-errors', '--output', 'json'))
    $text = Invoke-AzRaw -Arguments $fullArgs
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

    $fullArgs = @($Arguments + @('--only-show-errors', '--output', 'tsv'))
    return (Invoke-AzRaw -Arguments $fullArgs).Trim()
}

function Invoke-AzNoOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $fullArgs = @($Arguments + @('--only-show-errors', '--output', 'none'))
    [void](Invoke-AzRaw -Arguments $fullArgs)
}

function Set-KeyVaultSecretFromValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultName,

        [Parameter(Mandatory = $true)]
        [string]$SecretName,

        [Parameter(Mandatory = $true)]
        [string]$SecretValue,

        [Parameter(Mandatory = $true)]
        [hashtable]$Tags
    )

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempFile, $SecretValue, $utf8NoBom)

        $args = @(
            'keyvault', 'secret', 'set',
            '--vault-name', $VaultName,
            '--name', $SecretName,
            '--file', $tempFile,
            '--encoding', 'utf-8',
            '--content-type', 'text/plain'
        )

        if ($Tags.Count -gt 0) {
            $args += '--tags'
            foreach ($tagName in $Tags.Keys) {
                $args += "$tagName=$($Tags[$tagName])"
            }
        }

        Invoke-AzNoOutput -Arguments $args
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force
        }
    }
}

function Get-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $value = [string]$Row.$Name
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Manifest row is missing required value '$Name'."
    }

    return $value.Trim()
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI 'az' was not found. Install Azure CLI before running this script."
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}

if (-not $SkipLoginCheck) {
    try {
        [void](Invoke-AzJson -Arguments @('account', 'show'))
    }
    catch {
        throw "Azure CLI is not logged in or cannot read the current account. Run 'az login' first. $($_.Exception.Message)"
    }
}

$rows = @(Import-Csv -LiteralPath $ManifestPath)
if ($rows.Count -eq 0) {
    throw "Manifest contains no rows: $ManifestPath"
}

$requiredColumns = @('subscriptionId', 'resourceGroup', 'accountName', 'keyVaultName', 'secretName')
$columns = @($rows[0].PSObject.Properties.Name)
foreach ($column in $requiredColumns) {
    if ($columns -notcontains $column) {
        throw "Manifest is missing required column '$column'."
    }
}

if (-not $Execute) {
    Write-Host "DRY RUN: no keys will be regenerated and no Key Vault secrets will be updated."
}

$results = New-Object System.Collections.Generic.List[object]
$preflightRows = New-Object System.Collections.Generic.List[object]

foreach ($row in $rows) {
    $subscriptionId = Get-RequiredValue -Row $row -Name 'subscriptionId'
    $resourceGroup = Get-RequiredValue -Row $row -Name 'resourceGroup'
    $accountName = Get-RequiredValue -Row $row -Name 'accountName'
    $keyVaultName = Get-RequiredValue -Row $row -Name 'keyVaultName'
    $secretName = Get-RequiredValue -Row $row -Name 'secretName'
    $startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $status = 'Pending'
    $matchedSlot = ''
    $slotToRotate = ''
    $message = ''

    try {
        Invoke-AzNoOutput -Arguments @('account', 'set', '--subscription', $subscriptionId)

        $keys = Invoke-AzJson -Arguments @(
            'cognitiveservices', 'account', 'keys', 'list',
            '--name', $accountName,
            '--resource-group', $resourceGroup
        )

        $key1 = [string]$keys.key1
        $key2 = [string]$keys.key2
        if ([string]::IsNullOrWhiteSpace($key1) -or [string]::IsNullOrWhiteSpace($key2)) {
            throw "Could not read both Key1 and Key2 for account '$accountName'."
        }

        $currentSecret = Invoke-AzTsv -Arguments @(
            'keyvault', 'secret', 'show',
            '--vault-name', $keyVaultName,
            '--name', $secretName,
            '--query', 'value'
        )

        if ($currentSecret -eq $key1) {
            $matchedSlot = 'Key1'
        }
        elseif ($currentSecret -eq $key2) {
            $matchedSlot = 'Key2'
        }

        if ([string]::IsNullOrWhiteSpace($matchedSlot) -and -not $AllowUnmatchedSecret) {
            throw "Key Vault secret '$keyVaultName/$secretName' does not match Key1 or Key2 for '$accountName'. Confirm the mapping before rotating."
        }

        if ($KeySlot -eq 'Auto') {
            if ([string]::IsNullOrWhiteSpace($matchedSlot)) {
                throw "KeySlot Auto requires the Key Vault secret to match Key1 or Key2."
            }
            $slotToRotate = $matchedSlot
        }
        else {
            $slotToRotate = $KeySlot
            if (-not [string]::IsNullOrWhiteSpace($matchedSlot) -and $matchedSlot -ne $slotToRotate) {
                Write-Warning "Secret '$keyVaultName/$secretName' currently matches $matchedSlot, but $slotToRotate was requested."
            }
        }

        if (-not $Execute) {
            $status = 'DryRun'
            $message = "Would rotate $slotToRotate and update $keyVaultName/$secretName."
        }
        else {
            $status = 'Ready'
            $message = "Ready to rotate $slotToRotate and update $keyVaultName/$secretName."
            $preflightRows.Add([pscustomobject]@{
                SubscriptionId = $subscriptionId
                ResourceGroup = $resourceGroup
                AccountName = $accountName
                KeyVaultName = $keyVaultName
                SecretName = $secretName
                MatchedSlot = $matchedSlot
                RotatedSlot = $slotToRotate
                StartedAtUtc = $startedAtUtc
            })
        }
    }
    catch {
        $status = 'Failed'
        $message = $_.Exception.Message
    }
    finally {
        $results.Add([pscustomobject]@{
            StartedAtUtc = $startedAtUtc
            SubscriptionId = $subscriptionId
            ResourceGroup = $resourceGroup
            AccountName = $accountName
            KeyVaultName = $keyVaultName
            SecretName = $secretName
            MatchedSlot = $matchedSlot
            RotatedSlot = $slotToRotate
            Status = $status
            Message = $message
        })
    }
}

if ($Execute) {
    $failedPreflight = @($results | Where-Object { $_.Status -eq 'Failed' })
    if ($failedPreflight.Count -gt 0) {
        Write-Warning "Execution aborted because one or more manifest rows failed preflight. No keys were rotated."
    }
    else {
        $rotationGroups = $preflightRows |
            Group-Object -Property SubscriptionId, ResourceGroup, AccountName, RotatedSlot

        foreach ($group in $rotationGroups) {
            $first = $group.Group[0]
            $newValue = ''

            try {
                Invoke-AzNoOutput -Arguments @('account', 'set', '--subscription', $first.SubscriptionId)

                $newKeys = Invoke-AzJson -Arguments @(
                    'cognitiveservices', 'account', 'keys', 'regenerate',
                    '--name', $first.AccountName,
                    '--resource-group', $first.ResourceGroup,
                    '--key-name', $first.RotatedSlot
                )

                if ($first.RotatedSlot -eq 'Key1') {
                    $newValue = [string]$newKeys.key1
                }
                else {
                    $newValue = [string]$newKeys.key2
                }

                if ([string]::IsNullOrWhiteSpace($newValue)) {
                    throw "Regenerated key response did not include $($first.RotatedSlot) for '$($first.AccountName)'."
                }

                foreach ($secretRow in $group.Group) {
                    $rowStatus = 'Pending'
                    $rowMessage = ''
                    try {
                        $rotatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                        $rotatedBy = if ([string]::IsNullOrWhiteSpace($env:USERNAME)) { 'unknown' } else { $env:USERNAME }
                        $tags = @{
                            aiAccount = $secretRow.AccountName
                            resourceGroup = $secretRow.ResourceGroup
                            rotatedAtUtc = $rotatedAtUtc
                            rotatedBy = $rotatedBy
                        }

                        Set-KeyVaultSecretFromValue `
                            -VaultName $secretRow.KeyVaultName `
                            -SecretName $secretRow.SecretName `
                            -SecretValue $newValue `
                            -Tags $tags

                        $storedValue = Invoke-AzTsv -Arguments @(
                            'keyvault', 'secret', 'show',
                            '--vault-name', $secretRow.KeyVaultName,
                            '--name', $secretRow.SecretName,
                            '--query', 'value'
                        )

                        if ($storedValue -ne $newValue) {
                            throw "Post-update validation failed for '$($secretRow.KeyVaultName)/$($secretRow.SecretName)'."
                        }

                        $rowStatus = 'Rotated'
                        $rowMessage = "Rotated $($secretRow.RotatedSlot) and updated $($secretRow.KeyVaultName)/$($secretRow.SecretName)."
                    }
                    catch {
                        $rowStatus = 'Failed'
                        $rowMessage = $_.Exception.Message
                    }

                    $result = $results |
                        Where-Object {
                            $_.SubscriptionId -eq $secretRow.SubscriptionId -and
                            $_.ResourceGroup -eq $secretRow.ResourceGroup -and
                            $_.AccountName -eq $secretRow.AccountName -and
                            $_.KeyVaultName -eq $secretRow.KeyVaultName -and
                            $_.SecretName -eq $secretRow.SecretName
                        } |
                        Select-Object -First 1

                    if ($null -ne $result) {
                        $result.Status = $rowStatus
                        $result.Message = $rowMessage
                    }
                }
            }
            catch {
                foreach ($secretRow in $group.Group) {
                    $result = $results |
                        Where-Object {
                            $_.SubscriptionId -eq $secretRow.SubscriptionId -and
                            $_.ResourceGroup -eq $secretRow.ResourceGroup -and
                            $_.AccountName -eq $secretRow.AccountName -and
                            $_.KeyVaultName -eq $secretRow.KeyVaultName -and
                            $_.SecretName -eq $secretRow.SecretName
                        } |
                        Select-Object -First 1

                    if ($null -ne $result) {
                        $result.Status = 'Failed'
                        $result.Message = $_.Exception.Message
                    }
                }
            }
        }
    }
}

$results | Export-Csv -LiteralPath $ResultPath -NoTypeInformation
$results | Format-Table -AutoSize
Write-Host "Result CSV written to: $ResultPath"
