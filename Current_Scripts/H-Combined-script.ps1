[CmdletBinding()]
param(
    [string]$EnvironmentId = "cb1f75b0-80a1-e1f6-bd64-3b271177f91e",
    [string]$DataverseUrl  = "https://org59029660.crm.dynamics.com",

    [string]$Bot = "cr720_Agent2UITesting",
    [string]$BotComponentSchema = "cr720_Agent2UITesting.action.Computeruse-Computeruse",
    [string]$ConnectorApiName = "shared_computeroperator",

    [string]$AppDisplayName = "CUA-Dev-Testing",
    [int]$ClientSecretYears = 1,

    [string]$MachineName = $env:COMPUTERNAME,
    [string]$MachineDescription = "CUA",
    [string]$MachineUsername,
    [string]$ConnectionDisplayName,

    [string]$InstallerUrl = "https://go.microsoft.com/fwlink/?linkid=2102613",
    [string]$WorkDir = "$env:TEMP\pad-install",

    [switch]$Reinstall,
    [switch]$ForceMachineRegistration,
    [switch]$SkipConnectivityCheck,
    [switch]$SkipChromeExtension,
    [switch]$SkipEdgeExtension,
    [switch]$PocAllowWindowsHome,
    [switch]$NoPublish,

    [ValidateSet("EnvironmentApi", "LegacyPowerAppsApi")]
    [string]$ConnectionApiMode = "EnvironmentApi",

    # Optional preservation of the Azure resource-group portion of App-Registration.ps1.
    [switch]$ConfigureAzureResourceGroupRoles,
    [string]$SubscriptionId = "0c33fa37-4fa1-466d-a891-46af9e2f6e44",
    [string]$ResourceGroupName = "DemoResourceGroup",
    [string]$Location = "East US"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$DataverseUrl = $DataverseUrl.TrimEnd("/")
$ConnectionDisplayName = if ([string]::IsNullOrWhiteSpace($ConnectionDisplayName)) {
    "$MachineName-CUA"
} else {
    $ConnectionDisplayName.Trim()
}

$PadRoot = "${env:ProgramFiles(x86)}\Power Automate Desktop"
$RegExe  = Join-Path $PadRoot "PAD.MachineRegistration.Silent.exe"

# Microsoft Flow Service application ID.
# Microsoft documentation identifies this service as 7df0a125-d3be-4c96-aa54-591f83ff541c.
$FlowServiceAppId = "7df0a125-d3be-4c96-aa54-591f83ff541c"

$script:TenantId = $null
$script:ClientId = $null
$script:AppObjectId = $null
$script:ServicePrincipalObjectId = $null
$script:ClientSecret = $null
$script:DataverseAppToken = $null
$script:PowerPlatformAppToken = $null
$script:CreatedConnectionId = $null
$script:CreatedConnectionReferenceId = $null
$script:ResolvedBotId = $null

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

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run PowerShell as Administrator. PAD installation/registration and browser machine policies require elevation."
    }

    Write-Ok "Running as Administrator."
}

function Assert-AzureCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI (az) is required for the POC bootstrap but was not found in PATH."
    }

    Write-Ok "Azure CLI found."
}

function Assert-PacCli {
    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        throw "Power Platform CLI (pac) is required for agent publishing but was not found in PATH."
    }

    Write-Ok "Power Platform CLI found."
}

function Test-WindowsEdition {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Info "OS: $($os.Caption) ($($os.Version))"

    if ($os.Caption -match "Home") {
        if ($PocAllowWindowsHome) {
            Write-Warn "Windows Home detected. Continuing only because -PocAllowWindowsHome was passed. Power Automate direct machine connectivity is unsupported on Windows Home."
        } else {
            throw "Windows Home is not supported for direct Power Automate machine connectivity. Use Windows Pro, Enterprise, or Server. For diagnostics only, pass -PocAllowWindowsHome."
        }
    }
}

function Test-Connectivity {
    if ($SkipConnectivityCheck) {
        Write-Info "Connectivity checks skipped."
        return
    }

    $endpoints = @(
        "login.microsoftonline.com",
        "gateway.prod.island.powerapps.com",
        "go.microsoft.com"
    )

    foreach ($hostName in $endpoints) {
        $ok = Test-NetConnection -ComputerName $hostName -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue

        if ($ok) {
            Write-Info "$hostName`:443 reachable"
        } else {
            Write-Warn "$hostName`:443 unreachable. PAD registration/runtime may fail if the required Power Automate endpoints are blocked."
        }
    }
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

    $appWasJustCreated = $false

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
        $appWasJustCreated = $true
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

function Get-InstalledPadVersion {
    if (Test-Path $RegExe) {
        return (Get-Item $RegExe).VersionInfo.ProductVersion
    }

    return $null
}

function Install-Pad {
    Write-Step "Power Automate for desktop"

    $existing = Get-InstalledPadVersion
    if ($existing -and -not $Reinstall) {
        Write-Info "PAD already installed (version $existing)."
        Write-Info "Path: $RegExe"
        return
    }

    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $installer = Join-Path $WorkDir "Setup.Microsoft.PowerAutomate.exe"

    Write-Info "Downloading PAD installer..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $installer -UseBasicParsing

    Write-Info "Installing silently..."
    $proc = Start-Process `
        -FilePath $installer `
        -ArgumentList @("-Silent", "-Install", "-ACCEPTEULA") `
        -Wait `
        -PassThru `
        -NoNewWindow

    if ($proc.ExitCode -ne 0) {
        throw "PAD installer failed with exit code $($proc.ExitCode)."
    }

    if (-not (Test-Path $RegExe)) {
        throw "PAD install completed but '$RegExe' was not found."
    }

    Write-Ok "PAD installed. Registration tool version: $(Get-InstalledPadVersion)"
}

function ConvertTo-OrgUrl {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $candidate = $Value.Trim()
    if ($candidate -notmatch "^[a-z]+://") {
        $candidate = "https://$candidate"
    }

    $uri = $candidate -as [uri]
    if (-not $uri -or $uri.Scheme -ne "https") {
        return $null
    }

    return "https://$($uri.Host -replace '\.api\.', '.')"
}

function Get-LocalRegistration {
    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\Power Automate Desktop\Registration",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Power Automate Desktop\Registration"
    )

    foreach ($key in $keys) {
        if (-not (Test-Path $key)) {
            continue
        }

        $value = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $value -or $value.RegistrationState -ne "Registered") {
            continue
        }

        return [pscustomobject]@{
            MachineId = $value.MachineId
            GroupId   = (($value.GroupIds -split ",") | Where-Object { $_ } | Select-Object -First 1).Trim()
            OrgUrl    = ConvertTo-OrgUrl $value.OrgUri
            TenantId  = $value.TenantId
            Key       = $key
        }
    }

    return $null
}

function Register-PadMachine {
    Write-Step "Power Automate machine registration"

    $local = Get-LocalRegistration

    if ($local -and -not $ForceMachineRegistration) {
        Write-Info "Machine already registered."
        Write-Info "Machine ID: $($local.MachineId)"
        Write-Info "Group ID: $($local.GroupId)"
        Write-Info "Org: $($local.OrgUrl)"

        if ($local.OrgUrl -and $local.OrgUrl.TrimEnd("/") -ne $DataverseUrl) {
            throw "This Windows machine is already registered to '$($local.OrgUrl)', not '$DataverseUrl'. Use -ForceMachineRegistration only if replacing that registration is intentional."
        }

        return $local
    }

    if (-not (Test-Path $RegExe)) {
        throw "PAD machine registration executable is missing: $RegExe"
    }

    $arguments = @(
        "-register",
        "-applicationid", $script:ClientId,
        "-clientsecret",
        "-tenantid", $script:TenantId,
        "-environmentid", $EnvironmentId,
        "-machinename", $MachineName,
        "-machinedescription", $MachineDescription
    )

    if ($ForceMachineRegistration) {
        $arguments += "-force"
    }

    Write-Info "Registering '$MachineName' to environment $EnvironmentId."
    Write-Info "Service principal: $script:ClientId"
    Write-Info "Client secret is passed through stdin and is not printed."

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $RegExe
    $psi.Arguments = (
        $arguments |
        ForEach-Object {
            if ($_ -match "\s") { '"' + $_ + '"' } else { $_ }
        }
    ) -join " "

    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $PadRoot

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.WriteLine($script:ClientSecret)
    $proc.StandardInput.Close()

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    if ($stdout) {
        Write-Host $stdout
    }

    if ($stderr) {
        Write-Warn $stderr
    }

    if ($proc.ExitCode -ne 0) {
        throw @"
PAD machine registration failed (exit code $($proc.ExitCode)).

Check:
  - Windows edition supports direct connectivity.
  - Microsoft Flow Service Flow.Read.All was admin-consented.
  - The app is present in the environment as an application user.
  - The application user has sufficient Dataverse rights.
  - The client secret is valid.
  - Required Power Automate endpoints are reachable.
  - The machine is not registered to another environment unless -ForceMachineRegistration is intended.
"@
    }

    Start-Sleep -Seconds 2

    $local = Get-LocalRegistration
    if (-not $local) {
        throw "PAD reported registration success, but no local registration record could be read."
    }

    Write-Ok "Machine registration succeeded."
    Write-Info "Machine ID: $($local.MachineId)"
    Write-Info "Group ID: $($local.GroupId)"

    return $local
}

function Confirm-PadRuntime {
    Write-Step "PAD runtime services"

    $services =
        Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "UIFlow|PowerAutomate|PAD" }

    if (-not $services) {
        Write-Warn "No Power Automate service was found."
        return
    }

    foreach ($service in $services) {
        Write-Info "$($service.Name) [$($service.DisplayName)] - $($service.Status)"

        if ($service.Status -ne "Running" -and $service.StartType -ne "Disabled") {
            try {
                Start-Service $service.Name -ErrorAction Stop
                Write-Ok "Started $($service.Name)"
            } catch {
                Write-Warn "Could not start $($service.Name): $($_.Exception.Message)"
            }
        }
    }
}

function Enable-BrowserExtension {
    param(
        [Parameter(Mandatory)][string]$Browser,
        [Parameter(Mandatory)][string]$PolicyKey,
        [Parameter(Mandatory)][string]$ExtensionId,
        [string]$UpdateUrl
    )

    if (-not (Test-Path $PolicyKey)) {
        New-Item -Path $PolicyKey -Force | Out-Null
    }

    $policy = Get-Item -Path $PolicyKey

    foreach ($name in $policy.GetValueNames()) {
        if ($policy.GetValue($name) -like "$ExtensionId*") {
            Write-Info "$Browser extension already in machine forcelist."
            return
        }
    }

    $entry = if ($UpdateUrl) { "$ExtensionId;$UpdateUrl" } else { $ExtensionId }

    $index = 1
    while ($policy.GetValueNames() -contains "$index") {
        $index++
    }

    New-ItemProperty `
        -Path $PolicyKey `
        -Name "$index" `
        -Value $entry `
        -PropertyType String `
        -Force |
        Out-Null

    Write-Ok "$Browser Power Automate extension added to machine policy."
}

function Enable-BrowserExtensions {
    Write-Step "Browser extensions"

    if (-not $SkipChromeExtension) {
        Enable-BrowserExtension `
            -Browser "Chrome" `
            -PolicyKey "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist" `
            -ExtensionId "ljglajjnnkapghbckkcmodicjhacbfhk"
    }

    if (-not $SkipEdgeExtension) {
        Enable-BrowserExtension `
            -Browser "Edge" `
            -PolicyKey "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist" `
            -ExtensionId "kagpabjoboikccfdghpdlaaopmgpgfdc" `
            -UpdateUrl "https://edge.microsoft.com/extensionwebstore/api/v1/crx"
    }
}

function Get-PowerAutomateMachine {
    param([int]$Attempts = 12)

    $escapedName = $MachineName.Replace("'", "''")
    $filter = [uri]::EscapeDataString("name eq '$escapedName'")

    $path =
        "flowmachines?`$select=flowmachineid,name,statuscode,lastheartbeatdate,agentversion,_flowmachinegroupid_value" +
        "&`$filter=$filter"

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $rows = @((Invoke-Dataverse -Method Get -Path $path).value)

        if ($rows.Count -eq 1) {
            return $rows[0]
        }

        if ($rows.Count -gt 1) {
            throw "More than one Power Automate machine named '$MachineName' exists in the environment."
        }

        if ($attempt -lt $Attempts) {
            Write-Info "Machine not visible in Dataverse yet (attempt $attempt/$Attempts). Retrying..."
            Start-Sleep -Seconds 5
        }
    }

    throw "Power Automate machine '$MachineName' was not found in Dataverse."
}

function Enable-ComputerUse {
    param(
        [Parameter(Mandatory)]
        [string]$GroupId
    )

    Write-Step "Enable machine for Computer Use"

    $group = Invoke-Dataverse `
        -Method Get `
        -Path "flowmachinegroups($GroupId)?`$select=flowmachinegroupid,name,usagetype"

    Write-Info "Machine group: $($group.name) [$GroupId]"
    Write-Info "Current usagetype: $($group.usagetype)"

    if ($group.usagetype -eq 1) {
        Write-Ok "Already enabled for Computer Use."
        return
    }

    Invoke-Dataverse `
        -Method Patch `
        -Path "flowmachinegroups($GroupId)" `
        -Body @{ usagetype = 1 } |
        Out-Null

    $verify = Invoke-Dataverse `
        -Method Get `
        -Path "flowmachinegroups($GroupId)?`$select=flowmachinegroupid,name,usagetype"

    if ($verify.usagetype -ne 1) {
        throw "Computer Use PATCH completed but group usagetype is '$($verify.usagetype)' instead of 1."
    }

    Write-Ok "Machine group enabled for Computer Use."
    Write-Warn "This flag applies to every machine in the group."
}

function ConvertFrom-SecureStringToPlainText {
    param(
        [Parameter(Mandatory)]
        [SecureString]$SecureValue
    )

    $ptr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        if ($ptr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
}

function ConvertTo-EnvironmentApiId {
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )

    $compact = $Id.Replace("-", "")
    if ($compact.Length -lt 3) {
        throw "Environment ID '$Id' is not valid."
    }

    return $compact.Substring(0, $compact.Length - 2) + "." + $compact.Substring($compact.Length - 2)
}

function New-CuaConnection {
    param(
        [Parameter(Mandatory)][string]$FlowMachineGroupId,
        [Parameter(Mandatory)][string]$WindowsUsername,
        [Parameter(Mandatory)][string]$WindowsPassword
    )

    Write-Step "Create Computer Use connection as the signed-in user"

    $connectionId = (New-Guid).Guid.Replace("-", "")
    $script:CreatedConnectionId = $connectionId

    $payload = @{
        properties = @{
            displayName = $ConnectionDisplayName
            environment = @{
                id   = "/providers/Microsoft.PowerApps/environments/$EnvironmentId"
                name = $EnvironmentId
            }
            connectionParametersSet = @{
                name = "azureRelay"
                values = @{
                    targetId = @{
                        value = $FlowMachineGroupId
                    }
                    username = @{
                        value = $WindowsUsername
                    }
                    password = @{
                        value = $WindowsPassword
                    }
                    environment = @{
                        value = $EnvironmentId
                    }
                    xrmInstanceUri = @{
                        value = "$DataverseUrl/"
                    }
                    connectionType = @{
                        value = "azureRelay"
                    }
                }
            }
        }
    }

    $body = $payload | ConvertTo-Json -Depth 20

    # The connectivity service resolves the caller to a LICENSED USER and looks
    # for a Power Platform service plan. A service principal has none, so a
    # client-credentials token fails here with InvalidUserPlan - the same wall as
    # the code 10006 in context.md, hit one step earlier. This call has to be
    # delegated, exactly as CreateCUA-Connection.ps1 already does it.
    $script:PowerPlatformAppToken =
        Get-BootstrapUserToken -Resource "https://service.powerapps.com/"

    $environmentFilter = [uri]::EscapeDataString("environment eq '$EnvironmentId'")

    # Both -ConnectionApiMode branches built this identical URL and
    # ConvertTo-EnvironmentApiId was never called, so the switch was dead. The
    # parameter is kept so existing callers do not break.
    $url =
        "https://api.powerapps.com/providers/Microsoft.PowerApps/apis/" +
        "$ConnectorApiName/connections/$connectionId" +
        "?api-version=2016-11-01&%24filter=$environmentFilter"
    Write-Host "DEBUG CONNECTION URL:" 
    Write-Host $url
 
    $headers = @{
        Authorization = "Bearer $script:PowerPlatformAppToken"
        Accept        = "application/json"
    }

    Write-Info "Connection ID: $connectionId"
    Write-Info "Display name: $ConnectionDisplayName"
    Write-Info "Connector: $ConnectorApiName"
    Write-Info "Machine group targetId: $FlowMachineGroupId"
    Write-Info "API mode: $ConnectionApiMode"
    Write-Info "Windows password is not logged."

    try {
        $created = Invoke-RestMethod `
            -Method Put `
            -Uri $url `
            -Headers $headers `
            -ContentType "application/json" `
            -Body $body
    } catch {
        $safeError = (Get-ErrorBody $_) -replace '(?i)"password"\s*:\s*"[^"]+"', '"password":"<REDACTED>"'
        throw "Computer Use connection creation failed: $safeError"
    }

    Write-Ok "Computer Use connection create request succeeded."

    try {
        $verify = Invoke-RestMethod `
            -Method Get `
            -Uri $url `
            -Headers $headers
    } catch {
        throw "Connection was created but verification GET failed: $(Get-ErrorBody $_)"
    }

    $returnedTarget = $verify.properties.connectionParametersSet.values.targetId.value

    if ($returnedTarget -and $returnedTarget -ne $FlowMachineGroupId) {
        throw "Created connection targetId mismatch. Expected '$FlowMachineGroupId', returned '$returnedTarget'."
    }

    $status = $null
    if ($verify.properties.statuses) {
        $status = $verify.properties.statuses[0].status
    }

    Write-Ok "Connection verified against machine group."
    Write-Info "Connection status: $status"

    return [pscustomobject]@{
        ConnectionId = $connectionId
        Status       = $status
        Raw          = $verify
    }
}

function Get-ComputerUseBotComponent {
    $escapedSchema = $BotComponentSchema.Replace("'", "''")
    $filter = [uri]::EscapeDataString("schemaname eq '$escapedSchema'")

    $rows = @(
        (Invoke-Dataverse `
            -Method Get `
            -Path "botcomponents?`$select=botcomponentid,schemaname,name,data&`$filter=$filter").value
    )

    if ($rows.Count -eq 0) {
        # Controlled fallback for environments where the exact schema differs slightly.
        $fallback = [uri]::EscapeDataString("contains(schemaname,'Computeruse')")
        $rows = @(
            (Invoke-Dataverse `
                -Method Get `
                -Path "botcomponents?`$select=botcomponentid,schemaname,name,data&`$filter=$fallback").value
        )
    }

    if ($rows.Count -ne 1) {
        throw "Expected exactly one Computer Use bot component; found $($rows.Count). Pass the exact -BotComponentSchema."
    }

    return $rows[0]
}

function Get-BotComponentSolution {
    param(
        [Parameter(Mandatory)]
        [string]$BotComponentId
    )

    $objectFilter = [uri]::EscapeDataString("objectid eq $BotComponentId")

    $components = @(
        (Invoke-Dataverse `
            -Method Get `
            -Path "solutioncomponents?`$select=_solutionid_value&`$filter=$objectFilter").value
    )

    $candidateNames = @()

    foreach ($component in $components) {
        if (-not $component._solutionid_value) {
            continue
        }

        $solution =
            Invoke-Dataverse `
                -Method Get `
                -Path "solutions($($component._solutionid_value))?`$select=uniquename,friendlyname"

        if ($solution.uniquename -notin @("Default", "Active")) {
            $candidateNames += $solution.uniquename
        }
    }

    $candidateNames = @($candidateNames | Select-Object -Unique)

    if ($candidateNames.Count -eq 0) {
        throw "The Computer Use bot component is not in a non-default solution."
    }

    if ($candidateNames.Count -gt 1) {
        Write-Warn "Bot component appears in multiple non-default solutions: $($candidateNames -join ', '). Using '$($candidateNames[0])'."
    }

    return $candidateNames[0]
}

function Set-CuaToolBinding {
    param(
        [Parameter(Mandatory)]
        [string]$ConnectionId
    )

    Write-Step "Bind connection + machine to Computer Use tool"

    $component = Get-ComputerUseBotComponent
    $solutionName = Get-BotComponentSolution -BotComponentId $component.botcomponentid

    Write-Info "Bot component: $($component.schemaname)"
    Write-Info "Bot component ID: $($component.botcomponentid)"
    Write-Info "Solution: $solutionName"

    $linePattern = "(?m)^(\s*connectionReference:\s*)(\S+?)(?=[ \t\r]*$)"
    $match = [regex]::Match($component.data, $linePattern)

    if (-not $match.Success) {
        throw "Could not locate the connectionReference line in the Computer Use bot component data."
    }

    $currentLogicalName = $match.Groups[2].Value

    $prefix = if ($currentLogicalName -match "\.shared_computeroperator\.") {
        ($currentLogicalName -split "\.shared_computeroperator\.")[0]
    } else {
        $BotComponentSchema
    }

    $targetLogicalName = "$prefix.$ConnectorApiName.$ConnectionId"
    $escapedTargetName = $targetLogicalName.Replace("'", "''")
    $filter = [uri]::EscapeDataString("connectionreferencelogicalname eq '$escapedTargetName'")

    $targetRows = @(
        (Invoke-Dataverse `
            -Method Get `
            -Path "connectionreferences?`$select=connectionreferenceid,connectionreferencelogicalname,connectionreferencedisplayname,connectorid,connectionid&`$filter=$filter").value
    )

    if ($targetRows.Count -gt 1) {
        throw "Multiple Connection Reference rows have logical name '$targetLogicalName'."
    }

    if ($targetRows.Count -eq 1) {
        $targetRow = $targetRows[0]

        if ($targetRow.connectionid -ne $ConnectionId) {
            throw "Existing Connection Reference '$targetLogicalName' points to '$($targetRow.connectionid)', not '$ConnectionId'."
        }

        Write-Info "Reusing Connection Reference: $($targetRow.connectionreferenceid)"
    } else {
        try {
            Invoke-Dataverse `
                -Method Post `
                -Path "connectionreferences" `
                -SolutionUniqueName $solutionName `
                -Body @{
                    connectionreferencelogicalname = $targetLogicalName
                    connectionreferencedisplayname = $targetLogicalName
                    connectorid = "/providers/Microsoft.PowerApps/apis/$ConnectorApiName"
                    connectionid = $ConnectionId
                    iscustomizable = @{
                        Value = $false
                    }
                } |
                Out-Null
        } catch {
            $message = $_.Exception.Message

            if ($message -match "10006") {
                throw @"
Creating the Connection Reference failed with connectivity error 10006.

The supplied CUA-MachineSwitch.ps1 previously proved that an app cannot write
connectionid for a connection owned by somebody else, even with System Administrator.

In this combined flow the connection is intentionally created by THIS SAME service
principal first. If 10006 still occurs, verify that the Computer Use connection is
actually owned by this application user and that the service-principal connection
creation request was accepted as the app identity.
"@
            }

            throw
        }

        $targetRows = @(
            (Invoke-Dataverse `
                -Method Get `
                -Path "connectionreferences?`$select=connectionreferenceid,connectionreferencelogicalname,connectionreferencedisplayname,connectorid,connectionid&`$filter=$filter").value
        )

        if ($targetRows.Count -ne 1) {
            throw "Connection Reference create request completed, but the row could not be read back."
        }

        $targetRow = $targetRows[0]
        Write-Ok "Connection Reference created in solution '$solutionName'."
    }

    $script:CreatedConnectionReferenceId = $targetRow.connectionreferenceid

    $linkNav = "botcomponent_connectionreference"

    $linked = @(
        (Invoke-Dataverse `
            -Method Get `
            -Path "botcomponents($($component.botcomponentid))?`$select=botcomponentid&`$expand=$linkNav(`$select=connectionreferenceid)").$linkNav
    )

    foreach ($link in $linked) {
        if ($link.connectionreferenceid -eq $targetRow.connectionreferenceid) {
            continue
        }

        Invoke-Dataverse `
            -Method Delete `
            -Path "botcomponents($($component.botcomponentid))/$linkNav($($link.connectionreferenceid))/`$ref" |
            Out-Null

        Write-Info "Unlinked old Connection Reference: $($link.connectionreferenceid)"
    }

    if ($targetRow.connectionreferenceid -notin @($linked.connectionreferenceid)) {
        Invoke-Dataverse `
            -Method Post `
            -Path "botcomponents($($component.botcomponentid))/$linkNav/`$ref" `
            -Body @{
                "@odata.id" = "$DataverseUrl/api/data/v9.2/connectionreferences($($targetRow.connectionreferenceid))"
            } |
            Out-Null

        Write-Ok "Bot component linked to Connection Reference."
    } else {
        Write-Info "Bot component already linked to target Connection Reference."
    }

    if ($currentLogicalName -ne $targetLogicalName) {
        $newData = [regex]::Replace(
            $component.data,
            $linePattern,
            {
                param($replacementMatch)
                $replacementMatch.Groups[1].Value + $targetLogicalName
            }
        )

        Invoke-Dataverse `
            -Method Patch `
            -Path "botcomponents($($component.botcomponentid))" `
            -Body @{
                data = $newData
            } |
            Out-Null

        Write-Ok "Computer Use action connectionReference updated."
    } else {
        Write-Info "Computer Use action already names the target Connection Reference."
    }

    # Verification
    $verifiedComponent =
        Invoke-Dataverse `
            -Method Get `
            -Path "botcomponents($($component.botcomponentid))?`$select=botcomponentid,schemaname,data&`$expand=$linkNav(`$select=connectionreferenceid)"

    $verifiedLogicalName =
        [regex]::Match($verifiedComponent.data, $linePattern).Groups[2].Value

    if ($verifiedLogicalName -ne $targetLogicalName) {
        throw "Bot component verification failed. Expected '$targetLogicalName', read '$verifiedLogicalName'."
    }

    $verifiedRow =
        Invoke-Dataverse `
            -Method Get `
            -Path "connectionreferences($($targetRow.connectionreferenceid))?`$select=connectionreferenceid,connectionreferencelogicalname,connectorid,connectionid"

    if ($verifiedRow.connectionid -ne $ConnectionId) {
        throw "Connection Reference verification failed: connectionid '$($verifiedRow.connectionid)' != '$ConnectionId'."
    }

    $verifiedLinks = @($verifiedComponent.$linkNav)
    if ($verifiedLinks.Count -ne 1 -or
        $verifiedLinks[0].connectionreferenceid -ne $targetRow.connectionreferenceid) {
        throw "Bot component link verification failed."
    }

    $solutionFilter = [uri]::EscapeDataString("objectid eq $($targetRow.connectionreferenceid)")
    $solutionLinks = @(
        (Invoke-Dataverse `
            -Method Get `
            -Path "solutioncomponents?`$select=_solutionid_value&`$filter=$solutionFilter").value
    )

    $referenceSolutions = @()
    foreach ($solutionLink in $solutionLinks) {
        if (-not $solutionLink._solutionid_value) {
            continue
        }

        $solution =
            Invoke-Dataverse `
                -Method Get `
                -Path "solutions($($solutionLink._solutionid_value))?`$select=uniquename"

        $referenceSolutions += $solution.uniquename
    }

    if ($solutionName -notin $referenceSolutions) {
        throw "Connection Reference exists but is not in solution '$solutionName'."
    }

    Write-Ok "CUA tool binding verified."
    Write-Info "Connection Reference ID: $($targetRow.connectionreferenceid)"
    Write-Info "Logical name: $targetLogicalName"
    Write-Info "Connection ID: $ConnectionId"
    Write-Info "Solution: $solutionName"

    return [pscustomobject]@{
        BotComponentId           = $component.botcomponentid
        SolutionUniqueName       = $solutionName
        ConnectionReferenceId    = $targetRow.connectionreferenceid
        ConnectionReferenceName  = $targetLogicalName
    }
}

function Resolve-BotId {
    if ($Bot -as [guid]) {
        return $Bot
    }

    $escaped = $Bot.Replace("'", "''")
    $filter = [uri]::EscapeDataString("schemaname eq '$escaped' or name eq '$escaped'")

    try {
        $rows = @(
            (Invoke-Dataverse `
                -Method Get `
                -Path "bots?`$select=botid,schemaname,name&`$filter=$filter").value
        )

        if ($rows.Count -eq 1) {
            return $rows[0].botid
        }

        if ($rows.Count -gt 1) {
            throw "More than one bot matched '$Bot'. Pass the agent GUID with -Bot."
        }
    } catch {
        Write-Warn "Could not resolve bot GUID from Dataverse: $($_.Exception.Message)"
    }

    # PAC can support schema names in newer versions. Keep the supplied value as fallback.
    return $Bot
}

function Publish-CuaAgent {
    if ($NoPublish) {
        Write-Step "Publish skipped"
        Write-Warn "-NoPublish was passed. Authoring configuration is written, but the live runtime may still use the old binding."
        return
    }

    Write-Step "Publish Copilot Studio agent as service principal"

    Assert-PacCli

    $profileName = "CUA-SPN-" + $script:ClientId.Substring(0, 8)
    if ($profileName.Length -gt 30) {
        $profileName = $profileName.Substring(0, 30)
    }

    # Create a PAC service-principal auth profile. PAC requires the secret as an
    # argument for this command. The script itself never prints the command/secret.
    $authOutput = pac auth create `
        --name $profileName `
        --environment $DataverseUrl `
        --applicationId $script:ClientId `
        --clientSecret $script:ClientSecret `
        --tenant $script:TenantId 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "PAC service-principal authentication failed:`n$($authOutput -join "`n")"
    }

    pac auth select --name $profileName | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "PAC auth profile '$profileName' was created but could not be selected."
    }

    $script:ResolvedBotId = Resolve-BotId

    Write-Info "Publishing bot: $script:ResolvedBotId"

    $publishOutput =
        pac copilot publish `
            --environment $DataverseUrl `
            --bot $script:ResolvedBotId 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Agent publish failed:`n$($publishOutput -join "`n")"
    }

    Write-Ok "Agent published."
}

function Verify-EndToEnd {
    param(
        [Parameter(Mandatory)]$Machine,
        [Parameter(Mandatory)]$Binding
    )

    Write-Step "Final verification"

    if (-not $Machine.flowmachineid) {
        throw "Final verification: Flow Machine ID is empty."
    }

    if (-not $Machine._flowmachinegroupid_value) {
        throw "Final verification: Flow Machine Group ID is empty."
    }

    $group =
        Invoke-Dataverse `
            -Method Get `
            -Path "flowmachinegroups($($Machine._flowmachinegroupid_value))?`$select=flowmachinegroupid,name,usagetype"

    if ($group.usagetype -ne 1) {
        throw "Final verification: machine group is not enabled for Computer Use."
    }

    $ref =
        Invoke-Dataverse `
            -Method Get `
            -Path "connectionreferences($($Binding.ConnectionReferenceId))?`$select=connectionreferenceid,connectionreferencelogicalname,connectorid,connectionid"

    if ($ref.connectionid -ne $script:CreatedConnectionId) {
        throw "Final verification: Connection Reference points to the wrong connection."
    }

    Write-Ok "Machine exists in Dataverse."
    Write-Ok "Machine group is enabled for Computer Use."
    Write-Ok "Computer Use connection ID is bound to the Connection Reference."
    Write-Ok "Bot component binding was verified before publish."
    if (-not $NoPublish) {
        Write-Ok "Agent publish command succeeded."
    }
}

# ------------------------------- MAIN -------------------------------

$machinePasswordPlain = $null

try {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " CUA END-TO-END PROVISIONING POC - v4" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Info "Environment: $EnvironmentId"
    Write-Info "Dataverse: $DataverseUrl"
    Write-Info "Machine: $MachineName"
    Write-Info "Agent: $Bot"
    Write-Info "Computer Use component: $BotComponentSchema"

    Write-Step "Preflight"
    Assert-Administrator
    Test-WindowsEdition
    Test-Connectivity
    Connect-BootstrapAzureUser

    Get-OrCreate-EntraApp
    Ensure-FlowReadAllPermission
    New-ProvisioningClientSecret
    Configure-OptionalAzureResourceGroupRoles

    Add-AppUserToEnvironment
    Ensure-SystemAdministratorRole

    Write-Step "Authentication handoff"
    Write-Ok "Bootstrap az-login phase is complete."
    Write-Ok "All following Dataverse/API operations use Client ID + Client Secret unless a Microsoft CLI command requires its own configured service-principal profile."

    Install-Pad

    $localRegistration = Register-PadMachine
    Confirm-PadRuntime

    # Refresh Dataverse token after registration in case enough time has elapsed.
    $script:DataverseAppToken =
        Get-ServicePrincipalToken -Scope "$DataverseUrl/.default"

    $machine = Get-PowerAutomateMachine
    Write-Ok "Power Automate machine found in Dataverse."
    Write-Info "Flow Machine ID: $($machine.flowmachineid)"
    Write-Info "Flow Machine Group ID: $($machine._flowmachinegroupid_value)"
    Write-Info "Status code: $($machine.statuscode)"
    Write-Info "Last heartbeat: $($machine.lastheartbeatdate)"

    $groupId = $machine._flowmachinegroupid_value
    if ([string]::IsNullOrWhiteSpace($groupId) -and $localRegistration) {
        $groupId = $localRegistration.GroupId
    }

    if ([string]::IsNullOrWhiteSpace($groupId)) {
        throw "The registered machine has no Flow Machine Group ID."
    }

    Enable-ComputerUse -GroupId $groupId
    Enable-BrowserExtensions

    Write-Step "Windows credentials for Computer Use connection"

    if ([string]::IsNullOrWhiteSpace($MachineUsername)) {
        $MachineUsername = Read-Host "Windows username for '$MachineName'"
    }

    if ([string]::IsNullOrWhiteSpace($MachineUsername)) {
        throw "Windows username cannot be empty."
    }

    $machinePasswordSecure =
        Read-Host "Windows password for '$MachineUsername'" -AsSecureString

    $machinePasswordPlain =
        ConvertFrom-SecureStringToPlainText -SecureValue $machinePasswordSecure

    if ([string]::IsNullOrWhiteSpace($machinePasswordPlain)) {
        throw "Windows password cannot be empty."
    }

    $connection =
        New-CuaConnection `
            -FlowMachineGroupId $groupId `
            -WindowsUsername $MachineUsername.Trim() `
            -WindowsPassword $machinePasswordPlain

    # Remove plaintext Windows password as soon as the API call is complete.
    $machinePasswordPlain = $null
    $machinePasswordSecure = $null

    # Delegated, not app-only: creating the connection reference writes
    # connectionid, which the connectivity service only lets the connection's
    # owner do. App-only fails with code 10006 even holding System Administrator
    # (context.md, proven 2026-08-25). The owner is now the signed-in user.
    $script:DataverseAppToken =
        Get-BootstrapUserToken -Resource $DataverseUrl

    $binding =
        Set-CuaToolBinding `
            -ConnectionId $connection.ConnectionId

    Publish-CuaAgent

    Verify-EndToEnd `
        -Machine $machine `
        -Binding $binding

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " CUA PROVISIONING COMPLETED" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Environment ID:              $EnvironmentId"
    Write-Host "Dataverse:                   $DataverseUrl"
    Write-Host "Tenant ID:                   $script:TenantId"
    Write-Host "App Client ID:               $script:ClientId"
    Write-Host "Service Principal Object ID: $script:ServicePrincipalObjectId"
    Write-Host "Machine:                     $MachineName"
    Write-Host "Flow Machine ID:             $($machine.flowmachineid)"
    Write-Host "Flow Machine Group ID:       $groupId"
    Write-Host "CUA Connection ID:           $script:CreatedConnectionId"
    Write-Host "Connection Reference ID:     $script:CreatedConnectionReferenceId"
    Write-Host "Published Bot:               $script:ResolvedBotId"
    Write-Host ""
    Write-Host "Client secret: created and used in-memory; value intentionally not printed." -ForegroundColor Yellow
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    # Best-effort cleanup of sensitive in-memory values.
    $machinePasswordPlain = $null
    $machinePasswordSecure = $null

    $script:DataverseAppToken = $null
    $script:PowerPlatformAppToken = $null
    $script:ClientSecret = $null
}
