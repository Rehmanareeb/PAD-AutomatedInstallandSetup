[CmdletBinding()]
param(
    [string]$BootstrapConfigB64 = "",

    [string]$TenantId = "",
    [string]$ClientId = "",
    [string]$ClientSecret = "",

    [string]$EnvironmentId = "",
    [string]$DataverseUrl  = "",

    [string]$MachineName = $env:COMPUTERNAME,
    [string]$MachineDescription = "CUA",

    [string]$InstallerUrl = "https://go.microsoft.com/fwlink/?linkid=2102613",
    [string]$WorkDir = "$env:TEMP\pad-install",

    [switch]$Reinstall,
    [switch]$ForceMachineRegistration = $true,
    [switch]$SkipConnectivityCheck,
    [switch]$SkipChromeExtension,
    [switch]$SkipEdgeExtension,
    [switch]$PocAllowWindowsHome
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$PadRoot = "${env:ProgramFiles(x86)}\Power Automate Desktop"
$RegExe  = Join-Path $PadRoot "PAD.MachineRegistration.Silent.exe"

$script:TenantId          = $null
$script:ClientId          = $null
$script:ClientSecret      = $null
$script:EnvironmentId     = $null
$script:DataverseUrl      = $null
$script:DataverseAppToken = $null
$script:BootstrapTenantId     = $null
$script:BootstrapClientId     = $null
$script:BootstrapClientSecret = $null

function Normalize-DataverseUrl {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $candidate = $Value.Trim().TrimEnd("/")
    if ($candidate -notmatch "^[a-z]+://") {
        $candidate = "https://$candidate"
    }

    if ($candidate -match "^http://") {
        $candidate = $candidate -replace "^http://", "https://"
    }

    return $candidate
}

function Initialize-InstallCredentials {
    if (-not [string]::IsNullOrWhiteSpace($BootstrapConfigB64)) {
        $bootstrapJson = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($BootstrapConfigB64.Trim())
        )
        $config = $bootstrapJson | ConvertFrom-Json

        if ($config.tenantId -and $config.clientId -and $config.clientSecret) {
            $script:BootstrapTenantId = "$($config.tenantId)".Trim()
            $script:BootstrapClientId = "$($config.clientId)".Trim()
            $script:BootstrapClientSecret = "$($config.clientSecret)".Trim()
        }

        if ($config.padApp) {
            $pad = $config.padApp
            $script:TenantId = if ($pad.tenantId) {
                "$($pad.tenantId)".Trim()
            } elseif ($config.tenantId) {
                "$($config.tenantId)".Trim()
            } else {
                $null
            }
            $script:ClientId = "$($pad.clientId)".Trim()
            $script:ClientSecret = "$($pad.clientSecret)".Trim()

            if ($pad.dataverseUrl) {
                $script:DataverseUrl = Normalize-DataverseUrl "$($pad.dataverseUrl)"
            }

            if ($pad.environmentId) {
                $script:EnvironmentId = "$($pad.environmentId)".Trim()
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:TenantId) -and -not [string]::IsNullOrWhiteSpace($TenantId)) {
        $script:TenantId = $TenantId.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($script:ClientId) -and -not [string]::IsNullOrWhiteSpace($ClientId)) {
        $script:ClientId = $ClientId.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($script:ClientSecret) -and -not [string]::IsNullOrWhiteSpace($ClientSecret)) {
        $script:ClientSecret = $ClientSecret.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($script:EnvironmentId) -and -not [string]::IsNullOrWhiteSpace($EnvironmentId)) {
        $script:EnvironmentId = $EnvironmentId.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($script:DataverseUrl) -and -not [string]::IsNullOrWhiteSpace($DataverseUrl)) {
        $script:DataverseUrl = Normalize-DataverseUrl $DataverseUrl
    }

    if ([string]::IsNullOrWhiteSpace($script:TenantId) -or
        [string]::IsNullOrWhiteSpace($script:ClientId) -or
        [string]::IsNullOrWhiteSpace($script:ClientSecret) -or
        [string]::IsNullOrWhiteSpace($script:DataverseUrl) -or
        [string]::IsNullOrWhiteSpace($script:EnvironmentId)) {
        throw @"
PAD install credentials are incomplete.
Required from the project form (or PAD_APP_* env vars on the server):
  - Tenant ID
  - Client ID (PAD app registration)
  - Client secret
  - Dataverse environment URL
  - Power Platform environment ID (GUID)
"@
    }

    Write-Info "Tenant ID: $script:TenantId"
    Write-Info "Client ID: $script:ClientId"
    Write-Info "Dataverse URL: $script:DataverseUrl"
    Write-Info "Environment ID: $script:EnvironmentId"
}

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

function Get-ApplicationToken {
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Scope
    )

    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $Scope
    }

    $response = Invoke-RestMethod `
        -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $body

    if (-not $response.access_token) {
        throw "Microsoft Entra token endpoint returned no access token for '$Scope'."
    }

    return $response.access_token
}

function Get-AdminApplicationToken {
    param(
        [Parameter(Mandatory)]
        [string]$Scope
    )

    $tenantId = $script:BootstrapTenantId
    $clientId = $script:BootstrapClientId
    $clientSecret = $script:BootstrapClientSecret

    if ([string]::IsNullOrWhiteSpace($clientId)) {
        $tenantId = $script:TenantId
        $clientId = $script:ClientId
        $clientSecret = $script:ClientSecret
    }

    if ([string]::IsNullOrWhiteSpace($clientId) -or
        [string]::IsNullOrWhiteSpace($clientSecret) -or
        [string]::IsNullOrWhiteSpace($tenantId)) {
        throw "Admin service principal credentials are not available for application-user registration."
    }

    return Get-ApplicationToken `
        -ClientId $clientId `
        -ClientSecret $clientSecret `
        -TenantId $tenantId `
        -Scope $Scope
}

function Test-PadDataverseAccess {
    try {
        $token = Get-ServicePrincipalToken -Scope "$($script:DataverseUrl)/.default"
        $who = Invoke-Dataverse -Method Get -Path "WhoAmI" -Token $token
        if ($who.UserId) {
            $script:DataverseAppToken = $token
            return $true
        }
    } catch { }

    return $false
}

function Get-PadServicePrincipalObjectId {
    $token = Get-AdminApplicationToken -Scope "https://graph.microsoft.com/.default"
    $escapedAppId = $script:ClientId.Replace("'", "''")
    $filter = [uri]::EscapeDataString("appId eq '$escapedAppId'")
    $url = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter&`$select=id,appId"

    $result = Invoke-RestMethod `
        -Method Get `
        -Uri $url `
        -Headers @{ Authorization = "Bearer $token" }

    if (-not $result.value -or $result.value.Count -lt 1) {
        throw "Microsoft Graph could not find a service principal for app '$($script:ClientId)'."
    }

    return "$($result.value[0].id)".Trim()
}

function Add-PadAppUserViaBapApi {
    Write-Info "Calling Power Platform addAppUser API..."

    $token = Get-AdminApplicationToken -Scope "https://api.bap.microsoft.com/.default"
    $uri = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$($script:EnvironmentId)/addAppUser?api-version=2020-10-01"
    $body = @{
        servicePrincipalAppId = $script:ClientId
    } | ConvertTo-Json

    try {
        Invoke-RestMethod `
            -Method Post `
            -Uri $uri `
            -Headers @{
                Authorization = "Bearer $token"
                Accept        = "application/json"
            } `
            -ContentType "application/json" `
            -Body $body | Out-Null
    } catch {
        $detail = Get-ErrorBody $_
        throw "Power Platform addAppUser API failed: $detail"
    }

    Write-Ok "Power Platform API registered PAD app as application user (System Administrator)."
}

function Test-PacCliReady {
    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        return $false
    }

    $output = @(pac help 2>&1 | ForEach-Object { "$_" })
    $text = $output -join "`n"
    return $text -notmatch 'No Microsoft\.PowerApps\.CLI has been installed|Please run ''pac install latest'''
}

function Invoke-PacCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    if (-not (Test-PacCliReady)) {
        throw "Power Platform CLI is not ready. Run pac install latest first."
    }

    $output = @(pac @Arguments 2>&1 | ForEach-Object { "$_" })
    $text = ($output -join "`n").Trim()

    if ($text) {
        Write-Info $text
    }

    if ($text -match 'No Microsoft\.PowerApps\.CLI has been installed|Please run ''pac install latest''') {
        throw "Power Platform CLI is not fully installed: $text"
    }

    if ($text -match '(?m)^Error:' -or $text -match '(?m)\r?\nError:') {
        throw "pac $($Arguments -join ' ') reported an error: $text"
    }

    if ($LASTEXITCODE -ne 0) {
        throw "pac $($Arguments -join ' ') failed (exit $LASTEXITCODE): $text"
    }

    return $text
}

function Ensure-PacCliReady {
    if (Test-PacCliReady) {
        return
    }

    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $msi = Join-Path $env:TEMP "PowerAppsCLI.msi"
        Invoke-WebRequest -Uri "https://aka.ms/PowerAppsCLI" -OutFile $msi -UseBasicParsing
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", $msi, "/quiet", "/norestart") -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -notin @(0, 3010)) {
            throw "Power Platform CLI install failed with exit code $($proc.ExitCode)."
        }
    }

    if (-not (Test-PacCliReady)) {
        $installOutput = @(pac install latest 2>&1 | ForEach-Object { "$_" })
        if ($installOutput.Count -gt 0) {
            Write-Info ($installOutput -join "`n")
        }
        if ($LASTEXITCODE -ne 0) {
            throw "pac install latest failed with exit code $LASTEXITCODE."
        }
    }

    if (-not (Test-PacCliReady)) {
        throw "Power Platform CLI is still not ready."
    }
}

function Add-PadAppUserViaPac {
    Ensure-PacCliReady

    $tenantId = $script:BootstrapTenantId
    $clientId = $script:BootstrapClientId
    $clientSecret = $script:BootstrapClientSecret
    if ([string]::IsNullOrWhiteSpace($clientId)) {
        $tenantId = $script:TenantId
        $clientId = $script:ClientId
        $clientSecret = $script:ClientSecret
    }

    $spObjectId = Get-PadServicePrincipalObjectId

    Write-Info "pac auth create with admin service principal $clientId..."
    Invoke-PacCli -Arguments @("auth", "clear") | Out-Null
    Invoke-PacCli -Arguments @(
        "auth", "create",
        "--applicationId", $clientId,
        "--clientSecret", $clientSecret,
        "--tenant", $tenantId,
        "--name", "CUA-Bootstrap-Install"
    ) | Out-Null

    Write-Info "pac admin assign-user for PAD app $spObjectId..."
    Invoke-PacCli -Arguments @(
        "admin", "assign-user",
        "--environment", $script:DataverseUrl,
        "--user", $spObjectId,
        "--role", "System Administrator",
        "--application-user"
    ) | Out-Null

    Write-Ok "pac assign-user completed."
}

function Ensure-PadAppEnvironmentAccess {
    Write-Step "Ensure PAD app is a Power Platform application user"

    if (Test-PadDataverseAccess) {
        Write-Ok "PAD app already has Dataverse access."
        return
    }

    Write-Info "PAD app '$($script:ClientId)' is not yet an application user in environment $($script:EnvironmentId)."
    Write-Info "Attempting automatic registration with System Administrator role..."

    $errors = @()

    try {
        Add-PadAppUserViaBapApi
    } catch {
        $errors += $_.Exception.Message
        Write-Warn $_.Exception.Message
        Write-Info "Retrying with pac admin assign-user..."

        try {
            Add-PadAppUserViaPac
        } catch {
            $errors += $_.Exception.Message
            Write-Warn $_.Exception.Message
            Write-Warn "Admin service principal needs Power Platform Administrator (or Dynamics 365 Service Administrator) in Entra ID."
        }
    }

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        if (Test-PadDataverseAccess) {
            Write-Ok "PAD app authenticated to Dataverse."
            return
        }

        if ($attempt -lt 12) {
            Write-Info "Waiting for Dataverse access (attempt $attempt/12)..."
            Start-Sleep -Seconds 5
        }
    }

    throw @"
Could not add PAD app '$($script:ClientId)' as an application user in environment $($script:EnvironmentId).
Automatic registration failed:
$($errors -join "`n")
Ensure the admin service principal has Power Platform Administrator rights, then retry.
"@
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
        Uri     = "$($script:DataverseUrl)/api/data/v9.2/$Path"
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

        if ($local.OrgUrl -and $local.OrgUrl.TrimEnd("/") -ne $script:DataverseUrl) {
            throw "This Windows machine is already registered to '$($local.OrgUrl)', not '$($script:DataverseUrl)'. Use -ForceMachineRegistration only if replacing that registration is intentional."
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
        "-environmentid", $script:EnvironmentId,
        "-machinename", $MachineName,
        "-machinedescription", $MachineDescription
    )

    if ($ForceMachineRegistration) {
        $arguments += "-force"
    }

    Write-Info "Registering '$MachineName' to environment $($script:EnvironmentId)."
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
  - The app is present in the environment as an application user with sufficient rights.
  - The client secret is valid and not expired.
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


try {

    Write-Step "Preflight"
    Initialize-InstallCredentials
    Assert-Administrator
    Test-WindowsEdition
    Test-Connectivity
    Ensure-PadAppEnvironmentAccess

    Install-Pad

    $localRegistration = Register-PadMachine
    Confirm-PadRuntime

    # Token for the Dataverse lookups below (uses injected PAD app credentials).
    $script:DataverseAppToken =
        Get-ServicePrincipalToken -Scope "$($script:DataverseUrl)/.default"

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

}
catch {
    Write-Host ""
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    # Best-effort cleanup of sensitive in-memory values.
    $script:DataverseAppToken = $null
    $script:ClientSecret = $null
    $script:BootstrapClientSecret = $null
}