$SubscriptionId = "0c33fa37-4fa1-466d-a891-46af9e2f6e44"

$ResourceGroupName = "DemoResourceGroup"

$Location = "East US"

$AppDisplayName = "CUA-Provisioning-Service-POC"

$ClientSecretYears = 1

$account = az account show 2>$null | ConvertFrom-Json

if (-not $account) {

    Write-Host "Azure login required for first-time setup."

    az login

    if ($LASTEXITCODE -ne 0) {
        throw "Azure login failed."
    }
}

Write-Host "Azure login available."

az account set `
    --subscription $SubscriptionId

if ($LASTEXITCODE -ne 0) {
    throw "Could not select subscription."
}

Write-Host "Subscription selected."


$TenantId = az account show `
    --query tenantId `
    --output tsv

if ([string]::IsNullOrWhiteSpace($TenantId)) {
    throw "Could not retrieve Tenant ID."
}

Write-Host ""
Write-Host "Tenant ID:"
Write-Host $TenantId


$rgExists = az group exists `
    --name $ResourceGroupName

if ($rgExists -eq "false") {

    Write-Host "Creating Resource Group..."

    az group create `
        --name $ResourceGroupName `
        --location $Location `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Could not create Resource Group."
    }

    Write-Host "Resource Group created."
}
else {

    Write-Host "Resource Group already exists."
}


$existingAppId = az ad app list `
    --display-name $AppDisplayName `
    --query "[0].appId" `
    --output tsv

if (-not [string]::IsNullOrWhiteSpace($existingAppId)) {

    Write-Host ""
    Write-Host "An App Registration already exists:"
    Write-Host $existingAppId
    Write-Host ""

    throw "App Registration already exists. Stopping to avoid creating duplicate credentials."
}


$app = az ad app create `
    --display-name $AppDisplayName `
    --sign-in-audience AzureADMyOrg `
    --output json |
    ConvertFrom-Json

if (-not $app) {
    throw "Could not create App Registration."
}

$ClientId = $app.appId
$AppObjectId = $app.id

Write-Host "App Registration created."

Write-Host ""
Write-Host "Client ID:"
Write-Host $ClientId



$sp = az ad sp create `
    --id $ClientId `
    --output json |
    ConvertFrom-Json

if (-not $sp) {
    throw "Could not create Service Principal."
}

$ServicePrincipalObjectId = $sp.id

Write-Host "Service Principal created."

Write-Host ""
Write-Host "Service Principal Object ID:"
Write-Host $ServicePrincipalObjectId


$ClientSecret = az ad app credential reset `
    --id $ClientId `
    --append `
    --display-name "CUA-Provisioning-POC" `
    --years $ClientSecretYears `
    --query password `
    --output tsv

if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
    throw "Could not create Client Secret."
}

Write-Host "Client Secret created."

# Important:
# This secret is only returned when it is created.

$ResourceGroupScope = `
    "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

Write-Host ""
Write-Host "Resource Group Scope:"
Write-Host $ResourceGroupScope

az role assignment create `
    --assignee-object-id $ServicePrincipalObjectId `
    --assignee-principal-type ServicePrincipal `
    --role "Contributor" `
    --scope $ResourceGroupScope `
    --output none

if ($LASTEXITCODE -ne 0) {
    throw "Could not assign Contributor role."
}

Write-Host "Contributor role assigned."


az role assignment create `
    --assignee-object-id $ServicePrincipalObjectId `
    --assignee-principal-type ServicePrincipal `
    --role "User Access Administrator" `
    --scope $ResourceGroupScope `
    --output none

if ($LASTEXITCODE -ne 0) {
    throw "Could not assign User Access Administrator role."
}

Write-Host "User Access Administrator role assigned."

Write-Host "AZURE_TENANT_ID:"
Write-Host $TenantId

Write-Host ""
Write-Host "AZURE_CLIENT_ID:"
Write-Host $ClientId

Write-Host ""
Write-Host "AZURE_CLIENT_SECRET:"
Write-Host $ClientSecret

Write-Host ""
Write-Host "SERVICE_PRINCIPAL_OBJECT_ID:"
Write-Host $ServicePrincipalObjectId

Write-Host ""
Write-Host "SUBSCRIPTION_ID:"
Write-Host $SubscriptionId

Write-Host ""
Write-Host "RESOURCE_GROUP:"
Write-Host $ResourceGroupName

Write-Host ""
Write-Host "IMPORTANT:"
Write-Host "Save the Client Secret securely."
Write-Host "Azure will not show this secret value again."
Write-Host ""
 