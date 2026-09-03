#Requires -Version 7
<#
.SYNOPSIS
  Turns on static-website hosting for Cost Sentinel's storage account so
  status.json is served anonymously from the $web container - without setting
  allowBlobPublicAccess on the account (kept off across the whole portfolio).
  Run automatically by `azd provision` as a postprovision hook.
.NOTES
  Static-website hosting is a data-plane blob-service setting with no ARM/Bicep
  representation, so it cannot live in infra/. The account key is used rather
  than --auth-mode login because the deploying user has Contributor (which can
  list keys) but not necessarily a data-plane RBAC role.
#>
$ErrorActionPreference = 'Stop'

$account = $env:STORAGE_ACCOUNT_NAME
if (-not $account) {
    throw "STORAGE_ACCOUNT_NAME is not set - this script runs as an azd postprovision hook."
}

Write-Host "Enabling static-website hosting on storage account '$account'..."

$key = az storage account keys list --account-name $account --query '[0].value' --output tsv
if ($LASTEXITCODE -ne 0) { throw "Could not list keys for '$account'." }

az storage blob service-properties update `
    --account-name $account `
    --account-key $key `
    --static-website `
    --index-document status.json `
    --404-document status.json | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to enable static-website hosting on '$account'." }

$endpoint = az storage account show --name $account --query 'primaryEndpoints.web' --output tsv
Write-Host "Static-website hosting enabled. status.json will be served at ${endpoint}status.json"
