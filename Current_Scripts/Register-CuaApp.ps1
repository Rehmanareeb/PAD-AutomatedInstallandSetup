<#
.SYNOPSIS
  Part 2 of 2 - app registration. Creates the Entra app, its Flow permission,
  a client secret, and the Power Platform application user.

.DESCRIPTION
  Split out of H-Combined-script.ps1 at the point that script called its
  "Authentication handoff". Everything here runs as the bootstrap az-login user
  and is once per tenant/environment, not once per machine.

    1. Entra app registration + service principal.
    2. Microsoft Flow Service Flows.Read.All delegated scope + admin consent.
    3. Client secret.
    4. Optional Azure resource-group RBAC (-ConfigureAzureResourceGroupRoles).
    5. Application user in the environment, via the BAP addAppUser endpoint.
    6. System Administrator verified/assigned, then a service-principal WhoAmI
       to prove the credentials actually work before any machine uses them.

  Hands off to Install-CuaMachine.ps1 through three environment variables set in
  the current session: CUA_CLIENT_ID, CUA_TENANT_ID and PAD_SECRET. Run both in
  the same PowerShell session and the machine script needs no arguments. To
  provision a different machine, pass -ShowSecret and carry the three values
  over by hand.

  Needs an az-login user who can create app registrations, grant tenant-wide
  admin consent, and administer the target environment. Does not need to be
  elevated - nothing here touches the local machine.

.EXAMPLE
  .\Register-CuaApp.ps1

.EXAMPLE
  # Provisioning a machine elsewhere - print the secret so it can be carried over.
  .\Register-CuaApp.ps1 -AppDisplayName CUA-PROD -ShowSecret
#>
[CmdletBinding()]
param(
    [string]$EnvironmentId = "cb1f75b0-80a1-e1f6-bd64-3b271177f91e",
    [string]$DataverseUrl  = "https://org59029660.crm.dynamics.com",

    [string]$AppDisplayName = "CUA-TESTING1",
    [int]$ClientSecretYears = 1,

    # The secret is kept in memory and handed over through $env:PAD_SECRET.
    # Pass this only when the machine script runs in a different session.
    [switch]$ShowSecret,

    # Optional preservation of the Azure resource-group portion of App-Registration.ps1.
    [switch]$ConfigureAzureResourceGroupRoles,
    [string]$SubscriptionId = "0c33fa37-4fa1-466d-a891-46af9e2f6e44",
    [string]$ResourceGroupName = "DemoResourceGroup",
    [string]$Location = "East US"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$DataverseUrl = $DataverseUrl.TrimEnd("/")

# Microsoft Flow Service application ID.
# Microsoft documentation identifies this service as 7df0a125-d3be-4c96-aa54-591f83ff541c.
$FlowServiceAppId = "7df0a125-d3be-4c96-aa54-591f83ff541c"

$script:TenantId = $null
$script:ClientId = $null
$script:AppObjectId = $null
$script:ServicePrincipalObjectId = $null
$script:ClientSecret = $null
$script:DataverseAppToken = $null

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    WARNING: $Message" -ForegroundColor Yellow
}

function Get-ErrorBody {
    param($ErrorRecord)

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }

    try {
        $stream = $ErrorRecord.Exception.Response.GetResponseStream()
        if ($stream) {
            $reader = New-Object System.IO.StreamReader($stream)
            return $reader.ReadToEnd()
        }
    } catch { }

    return $ErrorRecord.Exception.Message
}

function Assert-AzureCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI (az) is required for the POC bootstrap but was not found in PATH."
    }

    Write-Ok "Azure CLI found."
}

function Connect-BootstrapAzureUser {
    Write-Step "POC bootstrap authentication"

    Assert-AzureCli

    $account = $null
    try {
        $account = az account show --output json 2>$null | ConvertFrom-Json
    } catch {
        $account = $null
    }

    if (-not $account) {
        Write-Info "No Azure CLI session. Launching az login..."
        az login --allow-no-subscriptions | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "az login failed."
        }

        $account = az account show --output json | ConvertFrom-Json
    }

    if (-not $account -or -not $account.tenantId) {
        throw "Could not determine the tenant from Azure CLI."
    }

    $script:TenantId = $account.tenantId

    Write-Ok "Bootstrap user authenticated: $($account.user.name)"
    Write-Info "Tenant: $script:TenantId"
    if ($account.id) {
        Write-Info "Subscription: $($account.id)"
    }
}

function Get-BootstrapUserToken {
    param(
        [Parameter(Mandatory)]
        [string]$Resource
    )

    $token = az account get-access-token `
        --resource $Resource `
        --query accessToken `
        --output tsv

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Azure CLI could not obtain a bootstrap user token for '$Resource'."
    }

    return $token.Trim()
}

function Get-ServicePrincipalToken {
    param(
        [Parameter(Mandatory)]
        [string]$Scope
    )

    if ([string]::IsNullOrWhiteSpace($script:ClientId) -or
        [string]::IsNullOrWhiteSpace($script:TenantId) -or
        [string]::IsNullOrWhiteSpace($script:ClientSecret)) {
        throw "Service-principal credentials have not been initialized."
    }

    $body = @{
        grant_type    = "client_credentials"
        client_id     = $script:ClientId
        client_secret = $script:ClientSecret
        scope         = $Scope
    }

    $response = Invoke-RestMethod `
        -Method Post `
        -Uri "https://login.microsoftonline.com/$script:TenantId/oauth2/v2.0/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $body

    if (-not $response.access_token) {
        throw "Microsoft Entra token endpoint returned no access token for '$Scope'."
    }

    return $response.access_token
}

function Invoke-Dataverse {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Get", "Post", "Patch", "Delete")]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Token = $script:DataverseAppToken,

        $Body,

        [string]$SolutionUniqueName
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw "No Dataverse token is available."
    }

    $headers = @{
        Authorization      = "Bearer $Token"
        Accept             = "application/json"
        "OData-Version"    = "4.0"
        "OData-MaxVersion" = "4.0"
    }

    if ($Method -eq "Patch") {
        $headers["If-Match"] = "*"
    }

    if ($SolutionUniqueName) {
        $headers["MSCRM.SolutionUniqueName"] = $SolutionUniqueName
    }

    $call = @{
        Method  = $Method
        Uri     = "$DataverseUrl/api/data/v9.2/$Path"
        Headers = $headers
    }

    if ($null -ne $Body) {
        $call.ContentType = "application/json"
        $call.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    try {
        return Invoke-RestMethod @call
    } catch {
        $message = Get-ErrorBody $_
        throw "$Method $($Path -replace '\?.*$', '') failed: $message"
    }
}

function Get-OrCreate-EntraApp {
    Write-Step "Entra app registration"

    # Query only actual appId values. Empty result means no app exists.
    $rawExistingAppIds = az ad app list `
        --display-name $AppDisplayName `
        --query "[].appId" `
        --output tsv 2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "Could not search Entra app registrations."
    }

    $existingAppIds = @(
        $rawExistingAppIds |
        ForEach-Object { "$_".Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    Write-Info "Existing matching app registrations found: $($existingAppIds.Count)"

    if ($existingAppIds.Count -gt 1) {
        throw "More than one Entra app registration is named '$AppDisplayName'. Rename/remove duplicates before continuing."
    }

    if ($existingAppIds.Count -eq 1) {
        $script:ClientId = $existingAppIds[0]
        Write-Info "Reusing existing app registration '$AppDisplayName'."
    }
    else {
        Write-Info "No existing app registration named '$AppDisplayName' was found. Creating a new one..."

        $newClientId = az ad app create `
            --display-name $AppDisplayName `
            --sign-in-audience AzureADMyOrg `
            --query appId `
            --output tsv

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($newClientId)) {
            throw "Could not create Entra app registration."
        }

        $script:ClientId = "$newClientId".Trim()
        Write-Ok "App registration created."
    }

    if ([string]::IsNullOrWhiteSpace($script:ClientId)) {
        throw "App registration has no application/client ID."
    }

    # Resolve application Object ID with retry because a newly created Entra object
    # can take a few seconds to become readable from every Microsoft Graph path.
    $appObjectId = $null
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $candidate = az ad app list `
            --filter "appId eq '$script:ClientId'" `
            --query "[0].id" `
            --output tsv 2>$null

        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($candidate)) {
            $appObjectId = "$candidate".Trim()
            break
        }

        if ($attempt -lt 12) {
            Write-Info "Waiting for Entra app propagation (attempt $attempt/12)..."
            Start-Sleep -Seconds 5
        }
    }

    if ([string]::IsNullOrWhiteSpace($appObjectId)) {
        throw "Could not resolve the Entra application object ID for client ID '$script:ClientId'."
    }

    $script:AppObjectId = $appObjectId

    Write-Info "Client ID: $script:ClientId"
    Write-Info "App Object ID: $script:AppObjectId"

    # IMPORTANT:
    # Do not call `az ad sp show --id <clientId>` here as a probe. A brand-new
    # application does not yet have a service principal, and `show` returns an
    # expected "Resource does not exist" error. With Windows PowerShell +
    # $ErrorActionPreference='Stop', that expected native error can terminate the
    # entire script before we get a chance to create the service principal.
    #
    # `az ad sp list --filter "appId eq '...'"` succeeds and returns an empty result
    # when no SP exists, so it is safe to use as the existence check.
    $servicePrincipalObjectId = $null

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $candidate = az ad sp list `
            --filter "appId eq '$script:ClientId'" `
            --query "[0].id" `
            --output tsv 2>$null

        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($candidate)) {
            $servicePrincipalObjectId = "$candidate".Trim()
            break
        }

        # If no SP exists, create it. A just-created application may need a short
        # Graph propagation delay before `az ad sp create --id <appId>` succeeds.
        Write-Info "Service principal not found. Creating it (attempt $attempt/12)..."

        $createOutput = $null
        $createSucceeded = $false

        # Temporarily prevent expected native stderr from becoming a terminating
        # PowerShell error while Graph propagation is still catching up.
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"

            $createOutput = az ad sp create `
                --id $script:ClientId `
                --query id `
                --output tsv 2>&1

            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($createOutput)) {
                $servicePrincipalObjectId = "$createOutput".Trim()
                $createSucceeded = $true
            }
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }

        if ($createSucceeded) {
            Write-Ok "Service principal created."
            break
        }

        if ($attempt -lt 12) {
            Write-Info "Entra application is still propagating. Retrying in 5 seconds..."
            Start-Sleep -Seconds 5
        }
    }

    if ([string]::IsNullOrWhiteSpace($servicePrincipalObjectId)) {
        throw "Could not create or resolve the service principal for application '$script:ClientId' after waiting for Entra propagation."
    }

    $script:ServicePrincipalObjectId = $servicePrincipalObjectId

    # Read back once through LIST, not SHOW, to verify the appId/SP mapping.
    $verifiedSp = az ad sp list `
        --filter "appId eq '$script:ClientId'" `
        --query "[0].{id:id,appId:appId,displayName:displayName}" `
        --output json |
        ConvertFrom-Json

    if ($LASTEXITCODE -ne 0 -or -not $verifiedSp) {
        throw "Service principal was created/resolved but could not be verified."
    }

    if ($verifiedSp.appId -ne $script:ClientId) {
        throw "Service principal verification failed: returned appId '$($verifiedSp.appId)' instead of '$script:ClientId'."
    }

    Write-Ok "Service principal verified."
    Write-Info "Service Principal Object ID: $script:ServicePrincipalObjectId"
}

function Ensure-FlowReadAllPermission {
    Write-Step "Microsoft Flow Service permission"

    # Microsoft documents Flow/Flows.Read.All for silent PAD registration.
    # IMPORTANT: Microsoft Flow Service exposes this as an OAuth2 delegated scope,
    # not as an Application appRole. The earlier combined script incorrectly looked
    # in appRoles for an Application permission, which is why it failed even though
    # the app and service principal were created correctly.

    $flowSpRaw = az ad sp list `
        --filter "appId eq '$FlowServiceAppId'" `
        --output json 2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "Could not query Microsoft Flow Service in Entra ID."
    }

    $flowSpRows = @($flowSpRaw | ConvertFrom-Json)

    if ($flowSpRows.Count -eq 0) {
        Write-Info "Microsoft Flow Service enterprise application is not present in this tenant. Creating its service principal..."

        $flowSpCreated = az ad sp create `
            --id $FlowServiceAppId `
            --output json |
            ConvertFrom-Json

        if ($LASTEXITCODE -ne 0 -or -not $flowSpCreated) {
            throw "Could not create/resolve Microsoft Flow Service ($FlowServiceAppId)."
        }

        $flowSp = $flowSpCreated
    }
    else {
        $flowSp = $flowSpRows[0]
    }

    if (-not $flowSp) {
        throw "Could not resolve Microsoft Flow Service ($FlowServiceAppId)."
    }

    Write-Info "Microsoft Flow Service found: $($flowSp.displayName)"
    Write-Info "Flow Service App ID: $FlowServiceAppId"

    # Actual scope value is normally "Flows.Read.All".
    # Keep "Flow.Read.All" as a compatibility fallback because Microsoft's silent
    # registration documentation labels it that way in the UI text.
    $flowReadScope = @(
        $flowSp.oauth2PermissionScopes |
        Where-Object {
            $_.isEnabled -ne $false -and
            $_.value -in @("Flows.Read.All", "Flow.Read.All")
        }
    ) | Select-Object -First 1

    if (-not $flowReadScope) {
        $availableScopes = @(
            $flowSp.oauth2PermissionScopes |
            Where-Object { $_.value } |
            Select-Object -ExpandProperty value
        )

        throw (
            "Microsoft Flow Service delegated permission Flows.Read.All could not be found. " +
            "Available OAuth scopes returned by Entra: " +
            ($availableScopes -join ", ")
        )
    }

    Write-Info "Resolved Flow permission: $($flowReadScope.value)"
    Write-Info "Permission ID: $($flowReadScope.id)"
    Write-Info "Permission type: Delegated OAuth scope"

    # Check whether this exact delegated permission is already configured.
    $existingPermissionsRaw = az ad app permission list `
        --id $script:ClientId `
        --output json

    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the API permissions on app '$script:ClientId'."
    }

    $existingPermissions = @($existingPermissionsRaw | ConvertFrom-Json)
    $alreadyAdded = $false

    foreach ($resource in $existingPermissions) {
        if ($resource.resourceAppId -ne $FlowServiceAppId) {
            continue
        }

        foreach ($access in @($resource.resourceAccess)) {
            if ($access.id -eq $flowReadScope.id -and $access.type -eq "Scope") {
                $alreadyAdded = $true
                break
            }
        }
    }

    if (-not $alreadyAdded) {
        Write-Info "Adding $($flowReadScope.value) to the app registration..."

        az ad app permission add `
            --id $script:ClientId `
            --api $FlowServiceAppId `
            --api-permissions "$($flowReadScope.id)=Scope" `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Could not add Microsoft Flow Service $($flowReadScope.value) delegated permission."
        }

        Write-Ok "$($flowReadScope.value) permission added."
    }
    else {
        Write-Info "$($flowReadScope.value) is already configured on the app registration."
    }

    # Grant tenant-wide consent for the delegated scope. This needs an Entra admin
    # account that is permitted to grant admin consent.
    Write-Info "Granting admin consent for configured API permissions..."

    az ad app permission admin-consent `
        --id $script:ClientId `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw @"
The Flow permission was added to the app, but Azure CLI could not grant admin consent.

The bootstrap az-login user must have permission to grant tenant-wide admin consent.
You can also grant it manually from:
Entra ID -> App registrations -> $AppDisplayName -> API permissions -> Grant admin consent
"@
    }

    Write-Ok "Flow permission configured and admin consent completed."
}

function New-ProvisioningClientSecret {
    Write-Step "Client secret"

    $displayName = "CUA-Provisioning-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"

    $secret = az ad app credential reset `
        --id $script:ClientId `
        --append `
        --display-name $displayName `
        --years $ClientSecretYears `
        --query password `
        --output tsv

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($secret)) {
        throw "Could not create the client secret."
    }

    $script:ClientSecret = $secret.Trim()

    Write-Ok "Client secret created and kept in memory."
    Write-Info "Secret value is intentionally NOT displayed."
}

function Configure-OptionalAzureResourceGroupRoles {
    if (-not $ConfigureAzureResourceGroupRoles) {
        return
    }

    Write-Step "Optional Azure resource-group permissions"

    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        throw "-ConfigureAzureResourceGroupRoles requires -SubscriptionId."
    }

    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Could not select Azure subscription '$SubscriptionId'."
    }

    $exists = az group exists --name $ResourceGroupName
    if ($exists -eq "false") {
        az group create `
            --name $ResourceGroupName `
            --location $Location `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Could not create resource group '$ResourceGroupName'."
        }

        Write-Ok "Resource group created: $ResourceGroupName"
    } else {
        Write-Info "Resource group already exists: $ResourceGroupName"
    }

    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

    foreach ($role in @("Contributor", "User Access Administrator")) {
        $existing = az role assignment list `
            --assignee-object-id $script:ServicePrincipalObjectId `
            --scope $scope `
            --query "[?roleDefinitionName=='$role'] | length(@)" `
            --output tsv

        if ([int]$existing -gt 0) {
            Write-Info "$role already assigned at resource-group scope."
            continue
        }

        az role assignment create `
            --assignee-object-id $script:ServicePrincipalObjectId `
            --assignee-principal-type ServicePrincipal `
            --role $role `
            --scope $scope `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Could not assign Azure RBAC role '$role'."
        }

        Write-Ok "$role assigned at $scope"
    }
}

function Add-AppUserToEnvironment {
    Write-Step "Power Platform application user"

    # Newer Microsoft Power Platform admin endpoint. Microsoft documents that a
    # newly added application user through this endpoint receives System Administrator.
    $bapToken = Get-BootstrapUserToken -Resource "https://api.bap.microsoft.com/"

    $headers = @{
        Authorization = "Bearer $bapToken"
        Accept        = "application/json"
    }

    $body = @{
        servicePrincipalAppId = $script:ClientId
    } | ConvertTo-Json -Compress

    $url =
        "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/" +
        "scopes/admin/environments/$EnvironmentId/addAppUser?api-version=2020-10-01"

    try {
        Invoke-RestMethod `
            -Method Post `
            -Uri $url `
            -Headers $headers `
            -ContentType "application/json" `
            -Body $body |
            Out-Null

        Write-Ok "Application user add request succeeded."
    } catch {
        # It can already exist. We verify/repair explicitly below rather than blindly
        # treating every add failure as fatal.
        Write-Warn "addAppUser returned: $(Get-ErrorBody $_)"
        Write-Info "Continuing to explicit Dataverse verification."
    }
}

function Ensure-SystemAdministratorRole {
    Write-Step "Verify application user + System Administrator"

    $bootstrapDvToken = Get-BootstrapUserToken -Resource $DataverseUrl

    $filter = [uri]::EscapeDataString("applicationid eq $script:ClientId")
    $path =
        "systemusers?`$select=systemuserid,fullname,applicationid,_businessunitid_value" +
        "&`$filter=$filter"

    $users = @((Invoke-Dataverse -Method Get -Path $path -Token $bootstrapDvToken).value)

    if ($users.Count -eq 0) {
        throw "The Entra service principal was not found as a Dataverse application user after addAppUser."
    }

    if ($users.Count -gt 1) {
        throw "Multiple Dataverse application users were found for application ID $script:ClientId."
    }

    $appUser = $users[0]
    $appUserId = $appUser.systemuserid
    $businessUnitId = $appUser._businessunitid_value

    Write-Ok "Dataverse application user found: $appUserId"

    if ([string]::IsNullOrWhiteSpace($businessUnitId)) {
        throw "Application user's business unit could not be determined."
    }

    $roleFilter = [uri]::EscapeDataString(
        "name eq 'System Administrator' and _businessunitid_value eq $businessUnitId"
    )

    $roles = @(
        (Invoke-Dataverse `
            -Method Get `
            -Path "roles?`$select=roleid,name,_businessunitid_value&`$filter=$roleFilter" `
            -Token $bootstrapDvToken).value
    )

    if ($roles.Count -eq 0) {
        throw "System Administrator role was not found in the application user's business unit."
    }

    $systemAdminRole = $roles[0]

    $expanded = Invoke-Dataverse `
        -Method Get `
        -Path "systemusers($appUserId)?`$select=systemuserid&`$expand=systemuserroles_association(`$select=roleid,name)" `
        -Token $bootstrapDvToken

    $hasSystemAdmin = @(
        $expanded.systemuserroles_association |
        Where-Object { $_.roleid -eq $systemAdminRole.roleid }
    ).Count -gt 0

    if (-not $hasSystemAdmin) {
        Write-Info "Assigning System Administrator explicitly..."

        Invoke-Dataverse `
            -Method Post `
            -Path "systemusers($appUserId)/systemuserroles_association/`$ref" `
            -Token $bootstrapDvToken `
            -Body @{
                "@odata.id" = "$DataverseUrl/api/data/v9.2/roles($($systemAdminRole.roleid))"
            } |
            Out-Null

        Write-Ok "System Administrator assigned."
    } else {
        Write-Info "System Administrator already assigned."
    }

    # Verify the service principal itself can authenticate to Dataverse.
    $lastError = $null
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            $script:DataverseAppToken =
                Get-ServicePrincipalToken -Scope "$DataverseUrl/.default"

            $who = Invoke-Dataverse `
                -Method Get `
                -Path "WhoAmI" `
                -Token $script:DataverseAppToken

            if ($who.UserId) {
                Write-Ok "Service-principal Dataverse authentication verified. UserId: $($who.UserId)"
                return
            }
        } catch {
            $lastError = $_.Exception.Message
        }

        if ($attempt -lt 12) {
            Write-Info "Waiting for Dataverse application-user propagation (attempt $attempt/12)..."
            Start-Sleep -Seconds 5
        }
    }

    throw "Service-principal Dataverse authentication did not become ready. Last error: $lastError"
}

# ------------------------------- MAIN -------------------------------

try {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " CUA APP REGISTRATION (part 2 of 2)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Info "Environment: $EnvironmentId"
    Write-Info "Dataverse: $DataverseUrl"
    Write-Info "App display name: $AppDisplayName"

    Connect-BootstrapAzureUser

    Get-OrCreate-EntraApp
    Ensure-FlowReadAllPermission
    New-ProvisioningClientSecret
    Configure-OptionalAzureResourceGroupRoles

    Add-AppUserToEnvironment
    Ensure-SystemAdministratorRole

    # Handoff. A script invoked normally runs in the caller's process, so these
    # survive for Install-CuaMachine.ps1 in the same session and nowhere else.
    $env:CUA_CLIENT_ID = $script:ClientId
    $env:CUA_TENANT_ID = $script:TenantId
    $env:PAD_SECRET    = $script:ClientSecret

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " APP REGISTRATION COMPLETED" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Environment ID:              $EnvironmentId"
    Write-Host "Dataverse:                   $DataverseUrl"
    Write-Host "Tenant ID:                   $script:TenantId"
    Write-Host "App Client ID:               $script:ClientId"
    Write-Host "Service Principal Object ID: $script:ServicePrincipalObjectId"
    Write-Host ""

    if ($ShowSecret) {
        Write-Host "Client secret: $script:ClientSecret" -ForegroundColor Yellow
        Write-Host "Azure will not show this value again. Store it now." -ForegroundColor Yellow
    } else {
        Write-Host "Client secret: created and kept in memory; value intentionally not printed." -ForegroundColor Yellow
        Write-Host "Re-run with -ShowSecret if the machine is provisioned from another session." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Next, in THIS session:" -ForegroundColor Cyan
    Write-Host "    .\Install-CuaMachine.ps1"
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    $script:DataverseAppToken = $null
    # $script:ClientSecret is deliberately NOT cleared - $env:PAD_SECRET is the
    # handoff to the machine script and clearing it here would break that.
}
