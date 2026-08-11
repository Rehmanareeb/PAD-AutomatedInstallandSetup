<#
.SYNOPSIS
  Phase 1 steps 1-4, automated with Azure CLI: create the Entra app registration
  for Power Automate machine registration, attach the Microsoft Flow Service
  permissions, grant admin consent, mint a client secret, and print the three
  values Setup_PAD.ps1 needs.

.DESCRIPTION
  Uses Azure CLI rather than the Microsoft Graph PowerShell module. Both call the
  same Graph endpoints; the difference is which client application signs in. The
  Graph PowerShell module signs in as "Microsoft Graph Command Line Tools", which
  is frequently not consented in a tenant and returns 403 on the first read.
  Azure CLI signs in as its own first-party app, which usually is.

  Prerequisites are handled automatically on first run:
    - removes the Microsoft.Graph.Authentication module if present
    - installs Azure CLI (winget, falling back to the MSI) if 'az' is missing

  Steps:
    1. az ad sp list             - read the Microsoft Flow Service scopes from
                                   the tenant, so no scope GUIDs are hardcoded.
    2. az ad app create          - create the registration with those scopes
                                   declared in requiredResourceAccess.
    3. az ad sp create           - the app needs a service principal before
                                   anything can be consented to it.
    4. az ad app permission grant - tenant-wide consent for the scopes.
    5. az ad app credential reset - create the client secret.

  STILL MANUAL afterwards: adding the app as an application user in
  admin.powerplatform.com. That is Dataverse, not Entra, and no Azure API
  reaches it. See README.md.

.PARAMETER DryRun
  Resolve permissions and print every command without writing anything to the
  tenant. Run this first.

.EXAMPLE
  .\Create_PadApp.ps1 -DryRun

.EXAMPLE
  .\Create_PadApp.ps1 -DisplayName 'pad-machine-registration'

.OUTPUTS
  Tenant ID, client ID and client secret value. Exit code 0 on success, 1 on failure.
#>

[CmdletBinding()]
param(
    [string]$DisplayName = 'pad-machine-registration',

    # Client secret lifetime.
    [int]$SecretYears = 1,

    # Print what would be sent, write nothing.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
# Check native exit codes explicitly rather than letting PS decide.
$PSNativeCommandUseErrorActionPreference = $false

# Well-known appId for "Microsoft Flow Service". Only a fallback if the
# display-name lookup finds nothing.
$FlowServiceAppId = '7df0a125-d3be-4c96-aa54-591f83ff541c'

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Info { param([string]$m) Write-Host "    $m" }

function Invoke-Az {
    <# Run az, fail loudly on non-zero exit, return parsed JSON. #>
    param(
        [string[]]$Arguments,
        [switch]$Write        # suppressed by -DryRun
    )
    if ($Write -and $DryRun) {
        Write-Host "    [dry run] az $($Arguments -join ' ')" -ForegroundColor Yellow
        return $null
    }
    Write-Verbose "az $($Arguments -join ' ')"
    $out = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed (exit $LASTEXITCODE). Re-run that command by hand to see the error."
    }
    if (-not $out) { return $null }
    return ($out | ConvertFrom-Json)
}

# ---------------------------- prerequisites ----------------------------

function Remove-GraphModule {
    $m = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication
    if (-not $m) { return }
    Write-Step 'Removing the Microsoft Graph PowerShell module'
    Remove-Module Microsoft.Graph.Authentication -Force -ErrorAction SilentlyContinue
    try {
        Uninstall-Module Microsoft.Graph.Authentication -AllVersions -Force -ErrorAction Stop
        Write-Ok 'Removed.'
    }
    catch {
        # Installed for all users, or in use. Not fatal - nothing here needs it.
        Write-Warning "Could not uninstall it: $($_.Exception.Message)"
    }
}

function Install-AzureCli {
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $v = (Invoke-Az @('version'))."azure-cli"
        Write-Info "Azure CLI present (version $v)"
        return
    }

    Write-Step 'Installing Azure CLI'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --exact --id Microsoft.AzureCLI --silent `
            --accept-package-agreements --accept-source-agreements
    } else {
        Write-Info 'winget not available - falling back to the MSI.'
        $msi = Join-Path $env:TEMP 'azure-cli.msi'
        Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindows' -OutFile $msi -UseBasicParsing
        Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn" -Wait
    }

    # The installer updates PATH for new sessions only.
    foreach ($p in @("$env:ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin",
                     "${env:ProgramFiles(x86)}\Microsoft SDKs\Azure\CLI2\wbin")) {
        if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) { $env:PATH += ";$p" }
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI installed but az is still not on PATH. Open a new shell and re-run.'
    }
    Write-Ok 'Azure CLI installed.'
}

function Connect-Azure {
    Write-Step 'Signing in'
    # --allow-no-subscriptions: a directory-only account has no Azure subscription,
    # and without this az login treats that as a failure.
    # Invoke-Az throws on a non-zero exit, and "not logged in" is one.
    $acct = $null
    try { $acct = Invoke-Az @('account', 'show', '--only-show-errors') } catch { }
    if (-not $acct) {
        & az login --allow-no-subscriptions --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
        $acct = Invoke-Az @('account', 'show')
    }
    Write-Ok "Signed in as $($acct.user.name)"
    Write-Info "Tenant: $($acct.tenantId)"
    return $acct
}

# ------------------------------- steps -------------------------------

function Get-FlowService {
    Write-Step 'Resolving Microsoft Flow Service permissions'
    # Read the scopes from the tenant rather than hardcoding GUIDs that drift.
    $sp = Invoke-Az @('ad', 'sp', 'list', '--filter', "displayName eq 'Microsoft Flow Service'",
                      '--query', '[0].{id:id,appId:appId,displayName:displayName,scopes:oauth2PermissionScopes}')
    if (-not $sp) {
        Write-Info "Not found by display name; falling back to appId $FlowServiceAppId"
        $sp = Invoke-Az @('ad', 'sp', 'show', '--id', $FlowServiceAppId,
                          '--query', '{id:id,appId:appId,displayName:displayName,scopes:oauth2PermissionScopes}')
    }
    if (-not $sp) {
        throw 'Microsoft Flow Service service principal not found in this tenant. It is created on first use of Power Automate - confirm Power Automate has been used here.'
    }

    $scopes = @($sp.scopes | Where-Object { $_.isEnabled })
    if (-not $scopes) { throw 'Microsoft Flow Service exposes no enabled delegated scopes.' }

    Write-Ok "$($sp.displayName) [$($sp.appId)]"
    Write-Info "Granting all $($scopes.Count) delegated scopes:"
    foreach ($s in $scopes) { Write-Info "  - $($s.value)" }
    return [pscustomobject]@{ Sp = $sp; Scopes = $scopes }
}

function Assert-NoExistingApp {
    $existing = Invoke-Az @('ad', 'app', 'list', '--filter', "displayName eq '$DisplayName'", '--query', '[0].appId')
    if ($existing) {
        throw "An app registration named '$DisplayName' already exists (appId $existing). Re-run with a different -DisplayName, or delete it first."
    }
}

function New-AppRegistration {
    param($Flow)

    Write-Step "Creating app registration '$DisplayName'"
    # az chokes on inline JSON quoting on Windows; hand it a file.
    $rra = @(
        @{
            resourceAppId  = $Flow.Sp.appId
            resourceAccess = @($Flow.Scopes | ForEach-Object { @{ id = $_.id; type = 'Scope' } })
        }
    )
    $rraFile = Join-Path $env:TEMP 'pad-required-resource-access.json'
    $json = $rra | ConvertTo-Json -Depth 10
    # A single-element array serialises as a bare object; az wants an array.
    if ($json -notmatch '^\s*\[') { $json = "[$json]" }
    Set-Content -Path $rraFile -Value $json -Encoding utf8

    $app = Invoke-Az @('ad', 'app', 'create',
                       '--display-name', $DisplayName,
                       '--sign-in-audience', 'AzureADMyOrg',
                       '--required-resource-accesses', "@$rraFile") -Write
    Remove-Item $rraFile -ErrorAction SilentlyContinue
    if ($DryRun) { return $null }

    Write-Ok "Application (client) ID: $($app.appId)"
    Write-Info "Object ID: $($app.id)"
    return $app
}

function New-AppServicePrincipal {
    param($App)

    Write-Step 'Creating the service principal'
    if ($DryRun) { return (Invoke-Az @('ad', 'sp', 'create', '--id', '<new app id>') -Write) }

    # A freshly created application is not always visible to the directory
    # immediately - replication lag, seconds not minutes.
    # ponytail: fixed retry; if this proves flaky, back off exponentially.
    foreach ($attempt in 1..5) {
        try   { $sp = Invoke-Az @('ad', 'sp', 'create', '--id', $App.appId); break }
        catch {
            if ($attempt -eq 5) { throw }
            Write-Info "Application not replicated yet (attempt $attempt) - retrying in 5s"
            Start-Sleep -Seconds 5
        }
    }
    Write-Ok "Service principal: $($sp.id)"
    return $sp
}

function Grant-AdminConsent {
    param($Flow, $App)

    Write-Step 'Granting tenant-wide admin consent'
    $appId = if ($DryRun) { '<new app id>' } else { $App.appId }
    Invoke-Az @('ad', 'app', 'permission', 'grant',
                '--id', $appId,
                '--api', $Flow.Sp.appId,
                '--scope', ($Flow.Scopes.value -join ' ')) -Write | Out-Null
    if (-not $DryRun) { Write-Ok 'Consent granted for all users in the tenant.' }
}

function New-ClientSecret {
    param($App)

    Write-Step 'Creating the client secret'
    $appId = if ($DryRun) { '<new app id>' } else { $App.appId }
    # --append so an existing credential is never silently deleted.
    $cred = Invoke-Az @('ad', 'app', 'credential', 'reset',
                        '--id', $appId,
                        '--years', "$SecretYears",
                        '--append',
                        '--display-name', 'pad-setup') -Write
    if ($DryRun) { return $null }
    Write-Ok "Secret created, valid for $SecretYears year(s)."
    return $cred
}

# ------------------------------- main -------------------------------
try {
    if ($DryRun) { Write-Host "`nDRY RUN - nothing will be written to the tenant." -ForegroundColor Yellow }

    Remove-GraphModule
    Install-AzureCli
    $acct = Connect-Azure

    $flow = Get-FlowService
    if (-not $DryRun) { Assert-NoExistingApp }

    $app  = New-AppRegistration -Flow $flow
    $sp   = New-AppServicePrincipal -App $app
    Grant-AdminConsent -Flow $flow -App $app
    $cred = New-ClientSecret -App $app

    if ($DryRun) {
        Write-Step 'Dry run complete'
        Write-Info 'Re-run without -DryRun to create the app.'
        exit 0
    }

    Write-Step 'Done - copy these now'
    Write-Host @"

    Tenant ID            : $($acct.tenantId)
    Client ID            : $($app.appId)
    Client secret value  : $($cred.password)

The secret value is shown ONCE. It cannot be retrieved again - if it is lost,
create a new one with: az ad app credential reset --id $($app.appId) --append

Register a machine with:

    `$env:PAD_SECRET = '$($cred.password)'
    .\Setup_PAD.ps1 -EnvironmentId <env-guid> -ApplicationId '$($app.appId)' -TenantId '$($acct.tenantId)'

STILL REQUIRED, and not automatable through any Azure API:
    admin.powerplatform.com -> Environments -> <env> -> Settings ->
    Users + permissions -> Application users -> + New app user
    Add '$DisplayName', assign the Desktop Flows Machine Owner role.
"@ -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
