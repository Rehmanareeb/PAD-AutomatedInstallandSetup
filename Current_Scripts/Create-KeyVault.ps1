$SubscriptionId = "0c33fa37-4fa1-466d-a891-46af9e2f6e44"

$ResourceGroupName = "DemoResourceGroup"

$Location = "East US"

$KeyVaultName = "kv-cua-fno-poc-Test01"

$PowerPlatformEnvironmentId = "44b93ad0-0453-e870-97a1-7aaa33028408,eaa3f01b-f9a9-ee0c-b124-b226cc662813"

$UsernameSecretName = "FnoUsername"

$PasswordSecretName = "FnoPassword"

function Check-LastCommand {
    param(
        [string]$Message
    )

    if ($LASTEXITCODE -ne 0) {
        throw $Message
    }
}


az account set `
    --subscription $SubscriptionId

Check-LastCommand "Could not select Azure subscription."

Write-Host "Subscription selected."

az provider register `
    --namespace Microsoft.PowerPlatform `
    --wait `
    --only-show-errors

Check-LastCommand "Could not register Microsoft.PowerPlatform resource provider."

Write-Host "Microsoft.PowerPlatform is registered."

$resourceGroupExists = az group exists `
    --name $ResourceGroupName

if ($resourceGroupExists -eq "false") {

    Write-Host "Creating Resource Group: $ResourceGroupName"

    az group create `
        --name $ResourceGroupName `
        --location $Location `
        --output none

    Check-LastCommand "Could not create Resource Group."

    Write-Host "Resource Group created."
}
else {

    Write-Host "Resource Group already exists."
}

$vaultId = az keyvault list `
    --resource-group $ResourceGroupName `
    --resource-type vault `
    --query "[?name=='$KeyVaultName'].id | [0]" `
    --output tsv

if ([string]::IsNullOrWhiteSpace($vaultId)) {

    Write-Host "Creating Key Vault: $KeyVaultName"

    az keyvault create `
        --name $KeyVaultName `
        --resource-group $ResourceGroupName `
        --location $Location `
        --enable-rbac-authorization true `
        --enable-purge-protection true `
        --output none

    Check-LastCommand "Could not create Key Vault."

    $vaultId = az keyvault show `
        --name $KeyVaultName `
        --resource-group $ResourceGroupName `
        --query id `
        --output tsv

    Write-Host "Key Vault created."
}
else {

    Write-Host "Key Vault already exists."

    $rbacEnabled = az keyvault show `
        --name $KeyVaultName `
        --resource-group $ResourceGroupName `
        --query "properties.enableRbacAuthorization" `
        --output tsv

    if ($rbacEnabled -ne "true") {

        throw "Existing Key Vault is not using Azure RBAC. Do not automatically change the permission model."
    }
}

Write-Host ""
Write-Host "Key Vault Resource ID:"
Write-Host $vaultId


$currentUserObjectId = az ad signed-in-user show `
    --query id `
    --output tsv

Check-LastCommand "Could not retrieve current Azure user."

Write-Host "Current user Object ID:"
Write-Host $currentUserObjectId



$currentUserRole = az role assignment list `
    --assignee-object-id $currentUserObjectId `
    --scope $vaultId `
    --role "Key Vault Secrets Officer" `
    --query "[0].id" `
    --output tsv `
    2>$null

if ([string]::IsNullOrWhiteSpace($currentUserRole)) {

    Write-Host "Assigning Key Vault Secrets Officer..."

    az role assignment create `
        --assignee-object-id $currentUserObjectId `
        --assignee-principal-type User `
        --role "Key Vault Secrets Officer" `
        --scope $vaultId `
        --output none

    Check-LastCommand "Could not assign Key Vault Secrets Officer role."

    Write-Host "Role assigned."
}
else {

    Write-Host "Key Vault Secrets Officer already assigned."
}



$currentUserSecretsUserRole = az role assignment list `
    --assignee-object-id $currentUserObjectId `
    --scope $vaultId `
    --role "Key Vault Secrets User" `
    --query "[0].id" `
    --output tsv `
    2>$null

if ([string]::IsNullOrWhiteSpace($currentUserSecretsUserRole)) {

    Write-Host "Assigning Key Vault Secrets User to current user..."

    az role assignment create `
        --assignee-object-id $currentUserObjectId `
        --assignee-principal-type User `
        --role "Key Vault Secrets User" `
        --scope $vaultId `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Could not assign Key Vault Secrets User to current user."
    }

    Write-Host "Key Vault Secrets User assigned to current user."
}
else {

    Write-Host "Current user already has Key Vault Secrets User."
}


$copilotServicePrincipalId = az ad sp list `
    --filter "displayName eq 'Microsoft Copilot Studio Service'" `
    --query "[0].id" `
    --output tsv

if ([string]::IsNullOrWhiteSpace($copilotServicePrincipalId)) {

    Write-Host "Trying legacy Power Virtual Agents Service name..."

    $copilotServicePrincipalId = az ad sp list `
        --filter "displayName eq 'Power Virtual Agents Service'" `
        --query "[0].id" `
        --output tsv
}

if ([string]::IsNullOrWhiteSpace($copilotServicePrincipalId)) {

    throw "Microsoft Copilot Studio Service / Power Virtual Agents Service could not be found."
}

Write-Host "Copilot Studio Service Principal Object ID:"
Write-Host $copilotServicePrincipalId



$copilotRole = az role assignment list `
    --assignee-object-id $copilotServicePrincipalId `
    --scope $vaultId `
    --role "Key Vault Secrets User" `
    --query "[0].id" `
    --output tsv `
    2>$null

if ([string]::IsNullOrWhiteSpace($copilotRole)) {

    Write-Host "Assigning Key Vault Secrets User to Copilot Studio..."

    az role assignment create `
        --assignee-object-id $copilotServicePrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role "Key Vault Secrets User" `
        --scope $vaultId `
        --output none

    Check-LastCommand "Could not assign Key Vault Secrets User to Copilot Studio."

    Write-Host "Copilot Studio role assigned."
}
else {

    Write-Host "Copilot Studio already has Key Vault Secrets User."
}


$dataverseAppId = "00000007-0000-0000-c000-000000000000"

$dataverseServicePrincipalId = az ad sp list `
    --filter "appId eq '$dataverseAppId'" `
    --query "[0].id" `
    --output tsv

if ([string]::IsNullOrWhiteSpace($dataverseServicePrincipalId)) {
    throw "Dataverse service principal could not be found."
}

Write-Host "Dataverse Service Principal Object ID:"
Write-Host $dataverseServicePrincipalId


$existingDataverseRole = az role assignment list `
    --assignee-object-id $dataverseServicePrincipalId `
    --scope $vaultId `
    --role "Key Vault Secrets User" `
    --query "[0].id" `
    --output tsv `
    2>$null

if ([string]::IsNullOrWhiteSpace($existingDataverseRole)) {

    Write-Host "Assigning Key Vault Secrets User to Dataverse..."

    az role assignment create `
        --assignee-object-id $dataverseServicePrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role "Key Vault Secrets User" `
        --scope $vaultId `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to assign Key Vault Secrets User to Dataverse."
    }

    Write-Host "Key Vault Secrets User assigned to Dataverse."
}
else {

    Write-Host "Dataverse already has Key Vault Secrets User."
}


$fnoUsername = Read-Host "Enter F&O Username"

$fnoPasswordSecure = Read-Host `
    "Enter F&O Password" `
    -AsSecureString

$passwordPointer = `
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $fnoPasswordSecure
    )

try {

    $fnoPassword = `
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $passwordPointer
        )
}
finally {

    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR(
        $passwordPointer
    )
}



function Set-KeyVaultSecret {

    param(
        [string]$SecretName,
        [string]$SecretValue
    )

    Write-Host ""
    Write-Host "Creating/updating secret: $SecretName"

    $tempFile = New-TemporaryFile

    try {

        [System.IO.File]::WriteAllText(
            $tempFile.FullName,
            $SecretValue,
            [System.Text.UTF8Encoding]::new($false)
        )

        $success = $false

        for ($attempt = 1; $attempt -le 12; $attempt++) {

            az keyvault secret set `
                --vault-name $KeyVaultName `
                --name $SecretName `
                --file $tempFile.FullName `
                --encoding utf-8 `
                --tags "AllowedEnvironments=$PowerPlatformEnvironmentId" `
                --output none `
                2>$null

            if ($LASTEXITCODE -eq 0) {

                $success = $true
                break
            }

            Write-Host "Secret creation not ready yet. Retrying..."
            Start-Sleep -Seconds 10
        }

        if (-not $success) {

            throw "Could not create secret $SecretName."
        }
    }
    finally {

        if (Test-Path $tempFile.FullName) {
            Remove-Item $tempFile.FullName -Force
        }
    }

    Write-Host "$SecretName created successfully."
}

Set-KeyVaultSecret `
    -SecretName $UsernameSecretName `
    -SecretValue $fnoUsername


Set-KeyVaultSecret `
    -SecretName $PasswordSecretName `
    -SecretValue $fnoPassword


# Remove plaintext password from variable after use

$fnoPassword = $null
$fnoPasswordSecure = $null

az keyvault secret show `
    --vault-name $KeyVaultName `
    --name $UsernameSecretName `
    --query "{Secret:name,Tags:tags}" `
    --output json

az keyvault secret show `
    --vault-name $KeyVaultName `
    --name $PasswordSecretName `
    --query "{Secret:name,Tags:tags}" `
    --output json

Write-Host "Subscription ID:"
Write-Host $SubscriptionId

Write-Host ""
Write-Host "Resource Group:"
Write-Host $ResourceGroupName

Write-Host ""
Write-Host "Key Vault:"
Write-Host $KeyVaultName

Write-Host ""
Write-Host "Username Secret:"
Write-Host $UsernameSecretName

Write-Host ""
Write-Host "Password Secret:"
Write-Host $PasswordSecretName

Write-Host ""
Write-Host "Allowed Environment:"
Write-Host $PowerPlatformEnvironmentId

 