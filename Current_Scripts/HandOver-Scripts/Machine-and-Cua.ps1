<#
.SYNOPSIS
  Hand-over step 2, standalone: turn this VM into a Power Automate machine, then
  point Agent 2's Computer Use tool at it. Flow steps 3 and 4.

.DESCRIPTION
  Self-contained. It calls no other script in this repo - every piece of logic it
  needs is in this file, so the HandOver-Scripts folder can be handed over on its
  own.

  Flow step 3 - machine setup and CUA enablement:

      3.1  install Power Automate for desktop, silently
      3.2  register this machine to the target environment, then enable the
           machine group for computer use
      3.3  create the Computer Use connection carrying the machine's Windows
           credential, and the Dataverse connection reference row that the
           agent binds to
      GATE: the machine is registered, visible in Dataverse, and the connection
      reports a target of the right machine group.

  Flow step 4 - agent configuration:

      4.1  find Agent 2's Computer Use action
      4.2  create or reuse the connection reference in the action's own solution
           and link it to the action
      4.3  repoint the action, then verify link, action, connectionid and
           solution membership before anything is published
      4.4  set Agent 2's authentication to manual (Custom Entra), discovering
           the Copilot Studio resource, environment, gateway and internal
           routing bot id at run time, then re-verify the binding from 4.3

  The agent is not published by default: publishing belongs to Share-Agents.ps1,
  so a half-configured agent never reaches the runtime. -PublishNow overrides.

  AUTHENTICATION, the part that is easy to get wrong. Three operations, three
  different identities, and no single credential covers all of them:

    * Machine registration cannot use a token. PAD.MachineRegistration.Silent.exe
      accepts a username, or an app id with a client secret - it provisions a
      LOCAL machine identity and an Azure Relay connection, not a row you POST.
      The secret is piped over stdin, never placed on the command line.
    * Enabling computer use is an app-only Dataverse call, using the same app
      registration.
    * Creating the Computer Use connection CANNOT be app-only. Authorisation
      comes from the connectivity service, and these connections are created
      with sharing disabled, so a service principal fails with code 10006 even
      holding System Administrator. That step, and the agent binding, use your
      delegated `az login` (or -Interactive for a device code).

  Secrets are taken as SecureString, converted only at the moment of use, and
  never written to disk or placed on a command line.

.NOTES
  STEP 4.4 TALKS TO UNDOCUMENTED ENDPOINTS. Copilot Studio publishes no
  supported API for setting an agent's authentication, so that step discovers
  the Copilot service principal, the environment, the PVA gateway and the
  internal routing bot id at run time, probing several candidate routes and
  validating each answer before using it. It is the part of this script most
  likely to break when Microsoft changes something, and the diagnostics it
  prints on failure are deliberately verbose. Nothing is written until every
  piece of discovery has succeeded, so a failure there leaves the agent's
  authentication exactly as it was.

  The binding from 4.3 is re-verified AFTER 4.4, because changing an agent's
  authentication mode can discard its connections - switching an agent OFF
  Custom Entra is known to. Setting it TO Custom Entra should not, but the
  check costs one call and turns a silent breakage into an error.

  DO NOT CLONE THIS VM once this script has run. The registration and machine
  identity do not survive it: the clone inherits a registration record that
  points at a machine it is not, which shows up later as a machine that
  registers but never comes online.

.PARAMETER OrgUrl
  Target Dataverse org URL, e.g. https://org35fd7a12.crm.dynamics.com
  A bare host or an .api. host is normalised.

.PARAMETER EnvironmentId
  Power Platform environment GUID that the machine registers into and the
  Computer Use connection is created in.

.PARAMETER TenantId
  Directory (tenant) id.

.PARAMETER ApplicationId
  Client id of the app registration used for silent machine registration and for
  the app-only call that enables computer use. It needs Microsoft Flow Service
  permissions with admin consent, and an application user in the target
  environment.

.PARAMETER ClientSecret
  That app's client secret, as a SecureString. Prompted for if omitted.

.PARAMETER MachineName
  Name this machine registers under, and the name looked up in Dataverse.
  Defaults to $env:COMPUTERNAME.

.PARAMETER MachineDescription
  Description stamped on the registration. Default 'CUA'.

.PARAMETER InstallerUrl
  Power Automate for desktop installer. Defaults to Microsoft's current fwlink.

.PARAMETER WorkDir
  Where the installer is downloaded. Default "$env:TEMP\pad-install".

.PARAMETER ConnectionName
  Display name for the Computer Use connection. Defaults to '<MachineName>-CUA'.

.PARAMETER MachineUsername
  Windows account that signs in to this machine. The connection carries it.

.PARAMETER MachinePassword
  That account's password, as a SecureString. Prompted for if omitted.

.PARAMETER Agent2SchemaName
  Schema name of the Computer Use agent, e.g. cr720_Agent2UITesting. Schema name,
  not display name. Used only to publish, so it is needed only with -PublishNow.

.PARAMETER Agent2CuaComponentSchema
  Schema name of Agent 2's Computer Use action, e.g.
  cr720_Agent2UITesting.action.Computeruse-Computeruse. The connection reference
  row is named <this>.shared_computeroperator.<connection id>.

.PARAMETER Agent2DisplayName
  Agent 2's DISPLAY name as it appears in Copilot Studio, e.g.
  'Agent 2 UI Testing'. Step 4.4 looks the bot up by display name, not schema
  name.

.PARAMETER AuthClientId
  Client id of the Entra app registration Agent 2 authenticates its users with.
  This is a different app from -ApplicationId.

.PARAMETER AuthClientSecret
  That app's client secret, as a SecureString. Prompted for if omitted.

.PARAMETER AuthTenantId
  Tenant of the authentication app. Defaults to -TenantId.

.PARAMETER SolutionUniqueName
  Unique name of the solution the agent lives in. Sent as a header during 4.4
  so the change lands in that solution rather than Default. Optional.

.PARAMETER ServiceProviderId
  Copilot Studio's identifier for the "Microsoft Entra ID" auth provider. The
  default is the same in every tenant; change it only if Microsoft does.

.PARAMETER AuthRedirectUrl
  OAuth redirect Copilot Studio registers for the agent. Defaults to the Bot
  Framework token service, which is what the designer uses.

.PARAMETER AuthResourceUri
  Resource the agent's token is requested for. Default https://graph.microsoft.com

.PARAMETER BapApiBaseUrl
  Business Application Platform API root, used to discover the PVA gateway.
  Default https://api.bap.microsoft.com

.PARAMETER Interactive
  Sign in with a device code for the delegated steps instead of reusing
  `az login`. Use this where the Azure CLI is not installed or is signed in as
  the wrong account. Step 4.4 always uses the Azure CLI - it needs several
  differently-scoped delegated tokens.

.PARAMETER AcceptChanges
  Do not pause for confirmation when the agent is already bound to a DIFFERENT
  connection. A first-time binding never prompts.

.PARAMETER PublishNow
  Publish Agent 2 as soon as the binding verifies, instead of leaving the
  publish to Share-Agents.ps1.

.PARAMETER SkipInstall
  Power Automate is already installed - skip the download and install.

.PARAMETER SkipRegistration
  Skip 3.1 and 3.2 entirely. The machine must already be registered.

.PARAMETER SkipComputerUse
  Register the machine but do not touch the machine group's usagetype.

.PARAMETER SkipConnection
  Skip 3.3. Requires -ConnectionName naming a connection that already exists.

.PARAMETER SkipBinding
  Skip 4.1 to 4.3.

.PARAMETER SkipManualAuth
  Skip 4.4. Agent 2 keeps whatever authentication the imported solution set.

.PARAMETER SkipBrowserExtensions
  Do not force-install the Power Automate browser extension via machine policy.

.PARAMETER SkipConnectivityCheck
  Skip the outbound reachability probe, for proxies that block the test but allow
  the traffic.

.PARAMETER Reinstall
  Download and install Power Automate even if it is already present.

.PARAMETER Force
  Re-register the machine even if it is already registered. THIS BREAKS EXISTING
  CONNECTIONS to the machine.

.EXAMPLE
  .\Machine-and-Cua.ps1 -OrgUrl https://org35fd7a12.crm.dynamics.com `
                        -EnvironmentId 20bbbb76-91c1-efde-bf32-8a5468336104 `
                        -TenantId edda99bb-bab6-4c4c-8aa1-4b99e8e09c1b `
                        -ApplicationId <app-guid> `
                        -MachineName CUA-UAT-01 `
                        -MachineUsername CONTOSO\svc-cua `
                        -Agent2CuaComponentSchema cr720_Agent2UITesting.action.Computeruse-Computeruse

  Full run. Prompts only for the two secrets.

.EXAMPLE
  .\Machine-and-Cua.ps1 -Force

  Re-register a machine whose registration record is stale - the usual fix after
  a VM was cloned from an image that already had Power Automate registered.

.EXAMPLE
  .\Machine-and-Cua.ps1 -SkipRegistration -SkipConnection -ConnectionName CUA-UAT-01-CUA

  The machine and its connection already exist - just rebind Agent 2.

.EXAMPLE
  .\Machine-and-Cua.ps1 -Help
#>
[CmdletBinding()]
param(
    [switch] $Help,

    # --- environment ----------------------------------------------------------
    [string] $OrgUrl,
    [string] $EnvironmentId,
    [string] $TenantId,

    # --- machine registration -------------------------------------------------
    [string] $ApplicationId,
    [securestring] $ClientSecret,
    [ValidateNotNullOrEmpty()]
    [string] $MachineName = $env:COMPUTERNAME,
    [ValidateNotNullOrEmpty()]
    [string] $MachineDescription = 'CUA',
    [ValidateNotNullOrEmpty()]
    [string] $InstallerUrl = 'https://go.microsoft.com/fwlink/?linkid=2102613',
    [ValidateNotNullOrEmpty()]
    [string] $WorkDir = "$env:TEMP\pad-install",
    [ValidateNotNullOrEmpty()]
    [string] $ChromeExtensionId = 'ljglajjnnkapghbckkcmodicjhacbfhk',
    [ValidateNotNullOrEmpty()]
    [string] $EdgeExtensionId   = 'kagpabjoboikccfdghpdlaaopmgpgfdc',

    # --- computer use connection ---------------------------------------------
    [string] $ConnectionName,
    [string] $MachineUsername,
    [securestring] $MachinePassword,

    # --- agent ----------------------------------------------------------------
    [string] $Agent2SchemaName,
    [string] $Agent2CuaComponentSchema,
    [string] $Agent2DisplayName,

    # --- agent manual (Custom Entra) authentication ---------------------------
    [string] $AuthClientId,
    [securestring] $AuthClientSecret,
    [string] $AuthTenantId,
    [string] $SolutionUniqueName,
    # Platform constants: the same in every tenant. Parameters so a Microsoft
    # change can be worked around without editing the script.
    [ValidateNotNullOrEmpty()]
    [string] $ServiceProviderId = '5232e24f-b6c6-4920-b09d-d93a520c92e9',
    [ValidateNotNullOrEmpty()]
    [string] $AuthRedirectUrl   = 'https://token.botframework.com/.auth/web/redirect',
    [ValidateNotNullOrEmpty()]
    [string] $AuthResourceUri   = 'https://graph.microsoft.com',
    [ValidateNotNullOrEmpty()]
    [string] $BapApiBaseUrl     = 'https://api.bap.microsoft.com',

    # --- flow control ---------------------------------------------------------
    [switch] $Interactive,
    [switch] $AcceptChanges,
    [switch] $PublishNow,
    [switch] $SkipInstall,
    [switch] $SkipRegistration,
    [switch] $SkipComputerUse,
    [switch] $SkipConnection,
    [switch] $SkipBinding,
    [switch] $SkipManualAuth,
    [switch] $SkipBrowserExtensions,
    [switch] $SkipConnectivityCheck,
    [switch] $Reinstall,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

# Windows PowerShell 5.1 still negotiates TLS 1.0/1.1 by default on some builds;
# every endpoint below requires 1.2.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$PadRoot         = "${env:ProgramFiles(x86)}\Power Automate Desktop"
$RegExe          = Join-Path $PadRoot 'PAD.MachineRegistration.Silent.exe'
$ConnectorApi    = 'shared_computeroperator'
$PowerAppsScope  = 'https://service.powerapps.com/'
# Microsoft's own public client, which every tenant already trusts for Dataverse -
# no app registration and no "allow public client flows" needed for a device code.
$PublicClientId  = '51f81489-12ee-4a9e-aaae-a2591f45987d'

# ==============================================================================
# output
# ==============================================================================
function Write-Stage { param([string] $m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Info  { param([string] $m) Write-Host "    $m" }
function Write-Ok    { param([string] $m) Write-Host "    $m" -ForegroundColor Green }
function Write-Gate  { param([string] $m) Write-Host "    GATE  $m" -ForegroundColor Green }

# ==============================================================================
# input
# ==============================================================================
function Read-RequiredValue {
    param([string] $Prompt, [string] $Value)
    while ([string]::IsNullOrWhiteSpace($Value)) { $Value = (Read-Host $Prompt).Trim() }
    $Value.Trim()
}

function Read-RequiredSecret {
    param([string] $Prompt, [securestring] $Value)
    while ($null -eq $Value -or $Value.Length -eq 0) { $Value = Read-Host $Prompt -AsSecureString }
    $Value
}

function ConvertFrom-Secure {
    param([securestring] $Secure)
    if ($null -eq $Secure) { return $null }
    [Net.NetworkCredential]::new('', $Secure).Password
}

function Read-RequiredGuid {
    param([string] $Prompt, [string] $Value)
    $v = Read-RequiredValue $Prompt $Value
    if (-not ($v -as [guid])) { throw "Not a valid GUID: '$v'" }
    $v
}

function ConvertTo-OrgUrl {
    <#
      Normalise anything org-shaped to https://<org>.crm.dynamics.com:
        orgc0ee9ebb.crm.dynamics.com     -> adds the scheme
        https://orgc0ee9ebb.api.crm.../  -> drops 'api.' and the trailing /
      The registry stores the .api. host; the token scope and the Web API both
      want the plain org host. Returns $null if it is not org-shaped.
    #>
    param([string] $Value)
    if (-not $Value) { return $null }
    $v = $Value.Trim()
    if ($v -notmatch '^[a-z]+://') { $v = "https://$v" }
    $uri = $v -as [uri]
    if (-not $uri -or $uri.Scheme -ne 'https' -or -not $uri.Host) { return $null }
    "https://$($uri.Host -replace '\.api\.', '.')"
}

# ==============================================================================
# state shared with the other hand-over scripts. Never holds a secret.
# ==============================================================================
$StatePath = Join-Path $PSScriptRoot 'handover-state.json'
$State = if (Test-Path -LiteralPath $StatePath) {
    Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
} else { [pscustomobject]@{} }

function Get-Fallback { param($Value, [string] $Key) if ($Value) { $Value } else { $State.$Key } }

function Save-State {
    param([hashtable] $Values)
    foreach ($k in $Values.Keys) {
        if ($Values[$k]) { $State | Add-Member -NotePropertyName $k -NotePropertyValue $Values[$k] -Force }
    }
    # 5.1 has no 'utf8NoBOM', and its -Encoding utf8 means UTF-8 WITH a BOM.
    # Write through .NET so both editions agree.
    [System.IO.File]::WriteAllText($StatePath, ($State | ConvertTo-Json -Depth 4),
                                   (New-Object System.Text.UTF8Encoding $false))
    Write-Info "state    $StatePath"
}

# ==============================================================================
# preflight
# ==============================================================================
function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw 'Installing and registering Power Automate needs an elevated session. Re-run as Administrator, or pass -SkipRegistration -SkipInstall if the machine is already set up.'
    }
    Write-Info 'Running as Administrator.'
}

function Test-WindowsEdition {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Info "OS: $($os.Caption) ($($os.Version))"
    # Home editions cannot host the machine-runtime service.
    if ($os.Caption -match 'Home') {
        throw "Power Automate machine registration is not supported on $($os.Caption). Use Pro, Enterprise or Server."
    }
}

function Test-Connectivity {
    if ($SkipConnectivityCheck) { Write-Info 'Connectivity check skipped.'; return }
    $targets = @(
        @{ Host = 'login.microsoftonline.com';           Port = 443; Required = $true  }
        @{ Host = 'gateway.prod.island.powerapps.com';   Port = 443; Required = $false }
        @{ Host = 'go.microsoft.com';                    Port = 443; Required = $false }
    )
    foreach ($t in $targets) {
        $ok = $false
        try { $ok = (Test-NetConnection -ComputerName $t.Host -Port $t.Port -WarningAction SilentlyContinue).TcpTestSucceeded }
        catch { $ok = $false }
        if ($ok) {
            Write-Info "$($t.Host):$($t.Port) reachable"
        } elseif ($t.Required) {
            throw "$($t.Host):$($t.Port) is unreachable. Registration cannot work without it."
        } else {
            Write-Warning ("$($t.Host):$($t.Port) UNREACHABLE. A machine needs *.dynamics.com, " +
                           '*.servicebus.windows.net and *.gateway.prod.island.powerapps.com allowed ' +
                           'through the proxy/firewall, or it will register and then never come online.')
        }
    }
}

# ==============================================================================
# local registration record
# ==============================================================================
function Get-LocalRegistration {
    <#
      Power Automate records its own registration under HKLM. This is the
      authoritative answer to "is THIS box registered" - it needs no credentials
      and no network, unlike asking Dataverse, which can only match on machine
      name and cannot tell two same-named machines apart.

      GroupIds can be missing or blank on a partial registration, and on a VM
      cloned from an image that was already registered. A pipeline that matches
      nothing yields no output at all, and calling .Trim() on that is what turns
      a recoverable "no group" into "You cannot call a method on a null-valued
      expression". Casting is no help either - [string]$null is $null on
      PowerShell 7 - so the result is forced into an array and the count checked
      before any method is called on it.
    #>
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Power Automate Desktop\Registration',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Power Automate Desktop\Registration') {
        if (-not (Test-Path $key)) { continue }
        $r = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $r -or $r.RegistrationState -ne 'Registered') { continue }
        $groups = @("$($r.GroupIds)" -split ',' | Where-Object { $_ })
        $group  = if ($groups.Count) { "$($groups[0])".Trim() } else { '' }
        return [pscustomobject]@{
            MachineId = "$($r.MachineId)"
            GroupId   = $group
            OrgUrl    = ConvertTo-OrgUrl $r.OrgUri
            TenantId  = "$($r.TenantId)"
            Key       = $key
        }
    }
    $null
}

# ==============================================================================
# install
# ==============================================================================
function Get-InstalledPad {
    if (Test-Path $RegExe) { return (Get-Item $RegExe).VersionInfo.ProductVersion }
    $null
}

function Install-Pad {
    $existing = Get-InstalledPad
    if ($existing -and -not $Reinstall) {
        Write-Info "Already installed (version $existing) - skipping. Use -Reinstall to force."
        return
    }
    Write-Info "Downloading from $InstallerUrl"
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $installer = Join-Path $WorkDir 'Setup.Microsoft.PowerAutomate.exe'
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $installer -UseBasicParsing
    Write-Info ("Downloaded {0} MB" -f [math]::Round((Get-Item $installer).Length / 1MB, 1))

    Write-Info 'Installing silently (desktop app, machine runtime, browser extensions).'
    # -ACCEPTEULA is mandatory for unattended installation.
    $proc = Start-Process -FilePath $installer -ArgumentList @('-Silent', '-Install', '-ACCEPTEULA') `
                          -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "Installer failed with exit code $($proc.ExitCode)." }

    $ver = Get-InstalledPad
    if (-not $ver) { throw "Install reported success but $RegExe is not there." }
    Write-Ok "Installed (version $ver)"
}

function Enable-BrowserExtensions {
    <#
      The installer ships the extension, but a user can still disable it. Listing
      it in ExtensionInstallForcelist machine policy makes the browser install it
      on next launch, enable it, and grey out the remove toggle. Edge is
      Chromium, so only the key and the id differ.
    #>
    if ($SkipBrowserExtensions) { Write-Info 'Browser extension policy skipped.'; return }
    $browsers = @(
        @{ Name = 'Chrome'; Key = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist';   Id = $ChromeExtensionId; Update = $null }
        @{ Name = 'Edge';   Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'; Id = $EdgeExtensionId;   Update = 'https://edge.microsoft.com/extensionwebstore/api/v1/crx' }
    )
    foreach ($b in $browsers) {
        if (-not (Test-Path $b.Key)) { New-Item -Path $b.Key -Force | Out-Null }
        $policy = Get-Item -Path $b.Key
        # An existing entry may carry a ';<update-url>' suffix, so match on the
        # id prefix rather than the whole string.
        $already = $false
        foreach ($name in $policy.GetValueNames()) {
            if ($policy.GetValue($name) -like "$($b.Id)*") { $already = $true; break }
        }
        if ($already) { Write-Info "$($b.Name): already in the forcelist."; continue }

        $entry = if ($b.Update) { "$($b.Id);$($b.Update)" } else { $b.Id }
        $index = 1
        while ($policy.GetValueNames() -contains "$index") { $index++ }
        New-ItemProperty -Path $b.Key -Name "$index" -Value $entry -PropertyType String -Force | Out-Null
        Write-Ok "$($b.Name): added $index = $entry (restart the browser to apply)"
    }
}

# ==============================================================================
# register
# ==============================================================================
function Register-Machine {
    param([string] $Secret)

    # -clientsecret carries NO value on the command line: the secret is read from
    # stdin, so it never appears in the process list.
    $argList = @('-register',
                 '-applicationid', $ApplicationId,
                 '-clientsecret',
                 '-tenantid', $TenantId,
                 '-environmentid', $EnvironmentId,
                 '-machinename', $MachineName,
                 '-machinedescription', $MachineDescription)
    if ($Force) { $argList += '-force' }

    Write-Info ('Command: PAD.MachineRegistration.Silent.exe ' + ($argList -join ' '))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $RegExe
    $psi.Arguments = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.WorkingDirectory       = $PadRoot

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.WriteLine($Secret)
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    if ($out) { Write-Host $out }
    if ($err) { Write-Warning $err }

    if ($proc.ExitCode -ne 0) {
        throw @"
Registration failed (exit code $($proc.ExitCode)).

Common causes:
  - No application user exists in the environment for this app registration.
  - The app's Microsoft Flow Service permissions were never admin-consented.
  - The application user lacks the Desktop Flows Machine Owner role.
  - The client secret is wrong or expired.
  - The machine is already registered elsewhere (re-run with -Force to override).
  - Outbound connectivity to the Power Automate cloud services is blocked.
"@
    }
    Write-Ok 'Registration succeeded.'
}

function Confirm-Runtime {
    # The runtime is a Windows service; the PAD GUI never needs to be launched.
    $svcs = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'UIFlow|PowerAutomate|PAD' }
    if (-not $svcs) {
        Write-Warning 'No Power Automate service found - the machine may not stay connected.'
        return
    }
    foreach ($s in $svcs) {
        Write-Info ('{0} [{1}] - {2}' -f $s.Name, $s.DisplayName, $s.Status)
        if ($s.Status -ne 'Running' -and $s.StartType -ne 'Disabled') {
            try   { Start-Service $s.Name -ErrorAction Stop; Write-Ok "  started $($s.Name)" }
            catch { Write-Warning "  could not start $($s.Name): $($_.Exception.Message)" }
        }
    }
}

# ==============================================================================
# tokens
# ==============================================================================
function Get-HttpErrorBody {
    <#
      Dataverse, AAD and the Power Apps API all explain themselves in the
      response body; a bare status code cannot tell "no application user here"
      from "its role lacks the privilege". PS 7 exposes the body on ErrorDetails,
      5.1 often only in the raw stream - so try both.
    #>
    param($ErrorRecord)
    if ($ErrorRecord.ErrorDetails.Message) { return $ErrorRecord.ErrorDetails.Message }
    try {
        $s = $ErrorRecord.Exception.Response.GetResponseStream()
        $s.Position = 0
        return (New-Object System.IO.StreamReader($s)).ReadToEnd()
    } catch { return $ErrorRecord.Exception.Message }
}

function Get-AppOnlyToken {
    <# Client credentials, for the calls a service principal is allowed to make. #>
    param([string] $Resource, [string] $Secret)
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ApplicationId
        client_secret = $Secret          # POST body, never the URL or a command line
        scope         = "$Resource/.default"
    }
    $token = Invoke-RestMethod -Method Post -Body $body `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    if (-not $token.access_token) { throw 'Token endpoint returned no access_token.' }
    $token.access_token
}

function Get-DeviceCodeToken {
    <# Delegated sign-in, for the writes app-only is not allowed to make. #>
    param([string] $Scope)
    $code = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $PublicClientId; scope = $Scope }

    Write-Host "`n$($code.message)`n" -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds([int]$code.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([int]$code.interval)
        try {
            return (Invoke-RestMethod -Method Post `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -Body @{
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id   = $PublicClientId
                    device_code = $code.device_code
                }).access_token
        }
        catch {
            # authorization_pending is the normal "not signed in yet" response;
            # anything else is fatal and worth showing verbatim.
            $body = Get-HttpErrorBody $_
            $err  = ''
            try { $err = ($body | ConvertFrom-Json).error } catch { }
            if ($err -eq 'authorization_pending') { continue }
            if ($err -eq 'slow_down') { Start-Sleep -Seconds 5; continue }
            throw "Sign-in failed: $body"
        }
    }
    throw 'Device code expired before sign-in completed.'
}

function Get-DelegatedToken {
    <#
      Creating a Computer Use connection cannot be app-only: authorisation comes
      from the connectivity service, and these connections are created with
      sharing disabled, so a service principal gets code 10006 even holding
      System Administrator. Hence a real user's token.
    #>
    param([string] $Resource)
    if ($Interactive) { return Get-DeviceCodeToken -Scope "$Resource/.default offline_access" }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) not found. Install it and run `az login`, or pass -Interactive to sign in with a device code.'
    }
    # --query/-o tsv so the token never lands in a file or the process list.
    $token = az account get-access-token --resource $Resource --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "az could not get a token for $Resource. Run 'az login' as the account that will own the connection.`n$token"
    }
    "$token".Trim()
}

# ==============================================================================
# Dataverse
# ==============================================================================
function Invoke-Dv {
    param(
        [string] $Method = 'Get',
        [string] $Path,
        $Body,
        [string] $Token,
        [string] $Solution,
        [switch] $Representation
    )
    $headers = @{
        Authorization      = "Bearer $Token"
        Accept             = 'application/json'
        'OData-Version'    = '4.0'
        'OData-MaxVersion' = '4.0'
    }
    # If-Match keeps a PATCH update-only; without it Dataverse would upsert.
    if ($Method -eq 'Patch') { $headers['If-Match'] = '*' }
    # Without this the row lands in the Default solution only, and the agent
    # publishes a package that does not contain it - which the runtime reports as
    # SystemError on every message.
    if ($Solution)       { $headers['MSCRM.SolutionUniqueName'] = $Solution }
    if ($Representation) { $headers['Prefer'] = 'return=representation' }

    $call = @{ Method = $Method; Uri = "$OrgUrl/api/data/v9.2/$Path"; Headers = $headers }
    if ($Body) {
        $call.ContentType = 'application/json'
        $call.Body        = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }
    try { Invoke-RestMethod @call }
    catch {
        $body = Get-HttpErrorBody $_
        $msg  = $body
        try { $msg = ($body | ConvertFrom-Json).error.message } catch { }
        # Query string dropped: it is noise, and keeps filter values out of logs.
        throw "$Method $($Path -replace '\?.*$', '') failed: $msg"
    }
}

function Find-FlowMachine {
    <#
      The machine's row in Dataverse. Present = registered to this environment.
      Matched on NAME within the environment, which is the only handle available -
      a machine of the same name registered from a DIFFERENT box looks identical
      from here. Attempts > 1 covers the lag after a fresh registration.
    #>
    param([string] $Token, [int] $Attempts = 1)
    $filter = "name eq '$($MachineName -replace "'", "''")'"
    $path   = 'flowmachines?$filter=' + [uri]::EscapeDataString($filter) +
              '&$select=name,statuscode,lastheartbeatdate,_flowmachinegroupid_value'
    foreach ($attempt in 1..$Attempts) {
        $row = @((Invoke-Dv -Path $path -Token $Token).value)[0]
        if ($row) { return $row }
        if ($attempt -lt $Attempts) {
            Write-Info "Machine not visible in Dataverse yet (attempt $attempt) - retrying in 5s"
            Start-Sleep -Seconds 5
        }
    }
    $null
}

function Enable-ComputerUse {
    <#
      "Enable for computer use" is not a machine setting - it is the usagetype
      column on the machine's GROUP (flowmachinegroups): 1 = computer use,
      0 = default desktop flows.

      usagetype is absent from Microsoft's published schema reference. It works
      today over the supported Dataverse Web API, but treat it as undocumented -
      hence fail-soft, with the portal toggle as the fallback.

      Returns the group id on success so the connection step can bind to it.
    #>
    param([string] $Token, [string] $GroupId)

    if ($GroupId) {
        Write-Info "Machine group from the local registration: $GroupId"
    } else {
        $row = Find-FlowMachine -Token $Token -Attempts 3
        if (-not $row) {
            throw @"
No machine named '$MachineName' exists in $OrgUrl.

The local registry says this box is registered, but the environment disagrees.
That combination normally means the registration record was inherited - the VM
was cloned from an image where Power Automate had already been registered, and
the clone carries a machine identity that is not its own.

Re-register this box from scratch:

    .\Machine-and-Cua.ps1 -Force

Do not clone the VM again afterwards.
"@
        }
        Write-Info ('Machine found (statuscode {0}, last heartbeat {1})' -f $row.statuscode, $row.lastheartbeatdate)
        $GroupId = $row._flowmachinegroupid_value
        if (-not $GroupId) {
            throw "Machine '$MachineName' has no machine group assigned. The computer-use flag lives on the group, so there is nothing to set. Re-register with -Force."
        }
    }

    if ($SkipComputerUse) {
        Write-Info 'Computer-use flag left alone (-SkipComputerUse).'
        return $GroupId
    }

    $group = Invoke-Dv -Path "flowmachinegroups($GroupId)?`$select=name,usagetype" -Token $Token
    Write-Info "Group: $($group.name) [$GroupId], usagetype = $($group.usagetype)"

    if ($group.usagetype -eq 1) {
        Write-Ok 'Already enabled for computer use - no change made.'
        return $GroupId
    }

    # Only usagetype. The portal also sends statecode/statuscode/
    # preferredqueuingtype/groupmetadata; including those risks overwriting
    # settings changed elsewhere.
    try {
        Invoke-Dv -Method Patch -Path "flowmachinegroups($GroupId)" -Body @{ usagetype = 1 } -Token $Token | Out-Null
        # Confirm it took, rather than trusting the 204.
        $after = Invoke-Dv -Path "flowmachinegroups($GroupId)?`$select=name,usagetype" -Token $Token
        if ($after.usagetype -ne 1) { throw "PATCH accepted but usagetype is still $($after.usagetype)." }
        Write-Ok 'Enabled for computer use (usagetype = 1).'
        Write-Warning "This applies to EVERY machine in group '$($group.name)', not just $MachineName."
    }
    catch {
        # Undocumented column: never let it fail the run. The portal toggle works.
        Write-Warning $_.Exception.Message
        Write-Host @"
Could not enable computer use automatically. Do it by hand:
    Power Automate -> Machines -> $MachineName -> Settings -> Enable for computer use -> Save
"@ -ForegroundColor Yellow
    }
    $GroupId
}

# ==============================================================================
# Computer Use connection
# ==============================================================================
function New-CuaConnection {
    <#
      PUTs a shared_computeroperator connection carrying the machine GROUP id and
      the Windows credential, then reads it back - targetId is the whole point of
      the connection and the PUT body is not documented to echo the parameter set.
      Returns the new connection id.
    #>
    param([string] $PowerAppsToken, [string] $GroupId, [string] $Username, [string] $Password)

    $connectionId = (New-Guid).Guid.Replace('-', '')
    Write-Info "New connection id: $connectionId"

    # The braces on ${connectionId} are load-bearing: '?' is a legal character in
    # a PowerShell variable name, so "$connectionId?api-version" reads as the
    # variable $connectionId?api - empty - and the API rejects the request with
    # InvalidApiVersion. Do not "simplify" them away.
    $uri = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis/" +
           "$ConnectorApi/connections/${connectionId}?api-version=2016-11-01" +
           "&%24filter=$([uri]::EscapeDataString("environment eq '$EnvironmentId'"))"

    $headers = @{ Authorization = "Bearer $PowerAppsToken"; Accept = 'application/json' }
    $body = @{
        properties = @{
            displayName = $ConnectionName
            environment = @{
                id   = "/providers/Microsoft.PowerApps/environments/$EnvironmentId"
                name = $EnvironmentId
            }
            connectionParametersSet = @{
                name   = 'azureRelay'
                values = @{
                    targetId       = @{ value = $GroupId }
                    username       = @{ value = $Username }
                    password       = @{ value = $Password }
                    environment    = @{ value = $EnvironmentId }
                    xrmInstanceUri = @{ value = "$OrgUrl/" }
                    connectionType = @{ value = 'azureRelay' }
                }
            }
        }
    } | ConvertTo-Json -Depth 20

    Write-Info "Binding $MachineName via targetId $GroupId (credentials redacted)."
    try {
        Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
    }
    catch {
        $detail = (Get-HttpErrorBody $_) -replace '(?i)"password"\s*:\s*"[^"]+"', '"password":"<REDACTED>"'
        throw @"
Creating the Computer Use connection failed: $detail

If this is code 10006, the identity is the problem, not the payload. These
connections are created with sharing disabled, so a service principal can never
create one - sign in as a real user with `az login`, or pass -Interactive.
"@
    }

    $connection = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    $returned = $connection.properties.connectionParametersSet.values.targetId.value
    if ($returned -ne $GroupId) {
        throw "Connection was created, but targetId is '$returned', expected '$GroupId'."
    }
    $status = @($connection.properties.statuses.status)[0]
    Write-Ok "Connection created and machine binding validated. Status: $status"
    $connectionId
}

function Get-CuaConnectionId {
    <# Find an existing Computer Use connection by display name. #>
    param([string] $PowerAppsToken, [string] $Name)
    $uri = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis/$ConnectorApi/connections" +
           "?api-version=2016-11-01&%24filter=$([uri]::EscapeDataString("environment eq '$EnvironmentId'"))"
    $headers = @{ Authorization = "Bearer $PowerAppsToken"; Accept = 'application/json' }
    $all = @((Invoke-RestMethod -Method Get -Uri $uri -Headers $headers).value)
    $hit = @($all | Where-Object { $_.properties.displayName -eq $Name })
    if ($hit.Count -gt 1) { throw "'$Name' matches $($hit.Count) Computer Use connections. Rename them so each is unique." }
    if ($hit.Count -eq 1) { return $hit[0].name }
    throw ("No Computer Use connection named '$Name' in this environment. Available:`n" +
           (($all | ForEach-Object { "    $($_.properties.displayName)  ->  $($_.name)" }) -join "`n"))
}

# ==============================================================================
# agent binding
# ==============================================================================
function Get-ActionSolution {
    <#
      The connection reference has to live in the same solution as the action, or
      it is not in the package the agent publishes. Read it off the action rather
      than hardcoding a name, so this survives being renamed or reused.
    #>
    param([string] $BotComponentId, [string] $Token)
    $path = 'solutioncomponents?$select=_solutionid_value&$filter=' +
            [uri]::EscapeDataString("objectid eq $BotComponentId")
    $names = @(@((Invoke-Dv -Path $path -Token $Token).value) | ForEach-Object {
        (Invoke-Dv -Path "solutions($($_._solutionid_value))?`$select=uniquename" -Token $Token).uniquename
    } | Where-Object { $_ -notin 'Default', 'Active' })
    if (-not $names.Count) {
        throw 'The Computer Use action is not in any solution but Default, so there is nowhere to put the connection reference. Bind a machine once in the designer instead.'
    }
    $names[0]
}

function Set-AgentBinding {
    <#
      Repoints Agent 2's Computer Use action at $ConnectionId: creates or reuses
      the connection reference row in the action's solution, links it to the
      action, rewrites the action's connectionReference line, and verifies all
      four facts before returning. Publishing a half-written binding succeeds and
      then fails every conversation, so nothing here is taken on trust.
    #>
    param([string] $Token, [string] $ConnectionId)

    $linkNav = 'botcomponent_connectionreference'
    $select  = 'connectionreferenceid,connectionreferencelogicalname,connectorid,connectionid'

    # --- 4.1 the action -------------------------------------------------------
    $filter = [uri]::EscapeDataString("schemaname eq '$Agent2CuaComponentSchema'")
    $comp = @((Invoke-Dv -Path "botcomponents?`$select=botcomponentid,schemaname,data&`$filter=$filter" -Token $Token).value)
    if ($comp.Count -ne 1) {
        throw "Expected exactly one bot component with schema name '$Agent2CuaComponentSchema', found $($comp.Count). Check the schema name - it is the ACTION's, e.g. cr720_Agent2UITesting.action.Computeruse-Computeruse."
    }
    $comp = $comp[0]

    $linePattern = '(?m)^(\s*connectionReference:\s*)(\S+?)(?=[ \t\r]*$)'
    $m = [regex]::Match($comp.data, $linePattern)
    if (-not $m.Success) { throw 'Could not find the connectionReference line in the bot component.' }
    $actionName = $m.Groups[2].Value
    if ($actionName -notmatch '\.shared_computeroperator\.') {
        throw "The action names '$actionName', which is not a Computer Use connection reference."
    }

    $prefix     = ($actionName -split '\.shared_computeroperator\.')[0]
    $targetName = "$prefix.$ConnectorApi.$ConnectionId"
    Write-Info "action currently -> $actionName"
    Write-Info "action target    -> $targetName"

    if ($actionName -eq $targetName) {
        $existing = @((Invoke-Dv -Path ("connectionreferences?`$select=$select&`$filter=" +
            [uri]::EscapeDataString("connectionreferencelogicalname eq '$targetName'")) -Token $Token).value)[0]
        if ($existing) { Write-Ok "Already bound to $ConnectionId - nothing to do."; return }
    }
    elseif (-not $AcceptChanges) {
        # Only a REBIND is worth pausing over: it moves the live agent to a
        # different machine. A first-time binding needs no ceremony.
        Write-Host @"

    The agent is currently bound to a different connection.
        from  $actionName
        to    $targetName

    This changes which machine the live agent runs on.
"@ -ForegroundColor Yellow
        if ((Read-Host '    Type YES to proceed') -ne 'YES') { throw 'Cancelled at the rebind confirmation.' }
    }

    $solution = Get-ActionSolution -BotComponentId $comp.botcomponentid -Token $Token
    Write-Info "solution         -> $solution"

    # --- 4.2 the connection reference row -------------------------------------
    $targetRow = @((Invoke-Dv -Path ("connectionreferences?`$select=$select&`$filter=" +
        [uri]::EscapeDataString("connectionreferencelogicalname eq '$targetName'")) -Token $Token).value)[0]

    if ($targetRow) {
        Write-Info "reference row    -> reusing $($targetRow.connectionreferenceid)"
    } else {
        Invoke-Dv -Method Post -Path 'connectionreferences' -Solution $solution -Token $Token -Body @{
            connectionreferencelogicalname = $targetName
            connectionreferencedisplayname = $targetName
            connectorid                    = "/providers/Microsoft.PowerApps/apis/$ConnectorApi"
            connectionid                   = $ConnectionId
            iscustomizable                 = @{ Value = $false }
        } | Out-Null
        $targetRow = @((Invoke-Dv -Path ("connectionreferences?`$select=$select&`$filter=" +
            [uri]::EscapeDataString("connectionreferencelogicalname eq '$targetName'")) -Token $Token).value)[0]
        if (-not $targetRow) { throw "Created '$targetName' but it cannot be read back." }
        Write-Ok "reference row    -> created $($targetRow.connectionreferenceid) in $solution"
    }

    # --- link the action to exactly this row ----------------------------------
    $linked = @((Invoke-Dv -Path "botcomponents($($comp.botcomponentid))?`$select=botcomponentid&`$expand=$linkNav(`$select=connectionreferenceid)" -Token $Token).$linkNav)
    foreach ($l in $linked | Where-Object { $_.connectionreferenceid -ne $targetRow.connectionreferenceid }) {
        Invoke-Dv -Method Delete -Path "botcomponents($($comp.botcomponentid))/$linkNav($($l.connectionreferenceid))/`$ref" -Token $Token | Out-Null
        Write-Info "unlinked $($l.connectionreferenceid)"
    }
    if ($targetRow.connectionreferenceid -in $linked.connectionreferenceid) {
        Write-Info 'link             -> already linked'
    } else {
        Invoke-Dv -Method Post -Path "botcomponents($($comp.botcomponentid))/$linkNav/`$ref" -Token $Token `
            -Body @{ '@odata.id' = "$OrgUrl/api/data/v9.2/connectionreferences($($targetRow.connectionreferenceid))" } | Out-Null
        Write-Ok "link             -> $($targetRow.connectionreferenceid)"
    }

    # --- 4.3 repoint the action ----------------------------------------------
    if ($actionName -ne $targetName) {
        $newData = [regex]::Replace($comp.data, $linePattern, {
            param($x) $x.Groups[1].Value + $targetName
        })
        Invoke-Dv -Method Patch -Path "botcomponents($($comp.botcomponentid))" -Token $Token -Body @{ data = $newData } | Out-Null
        Write-Ok 'action           -> repointed'
    }

    Test-AgentBinding -Token $Token -ConnectionId $ConnectionId -Solution $solution
}

function Test-AgentBinding {
    <#
      All four facts that have to agree for a published agent to actually reach
      the machine: the action's connectionReference line, a row answering to
      that name, that row carrying the right connectionid, and the row being in
      the same solution as the action - plus the action linked to exactly one
      reference. Publishing a half-written binding succeeds and then fails every
      conversation, so none of it is taken on trust.

      Also run again after the authentication step, since changing an agent's
      authentication mode can discard its connections.
    #>
    param([string] $Token, [string] $ConnectionId, [string] $Solution, [string] $Label = 'verified')

    $linkNav = 'botcomponent_connectionreference'
    $select  = 'connectionreferenceid,connectionreferencelogicalname,connectorid,connectionid'
    $linePattern = '(?m)^(\s*connectionReference:\s*)(\S+?)(?=[ \t\r]*$)'

    $filter = [uri]::EscapeDataString("schemaname eq '$Agent2CuaComponentSchema'")
    $comp = @((Invoke-Dv -Path "botcomponents?`$select=botcomponentid,data&`$filter=$filter" -Token $Token).value)[0]
    if (-not $comp) { throw "Verification failed: no bot component with schema name '$Agent2CuaComponentSchema'." }

    $nowName = [regex]::Match($comp.data, $linePattern).Groups[2].Value
    $expected = ($nowName -split '\.shared_computeroperator\.')[0] + ".$ConnectorApi.$ConnectionId"
    if ($nowName -ne $expected) {
        throw "Verification failed: the action reads back as '$nowName', expected '$expected'."
    }

    $nowRow = @((Invoke-Dv -Path ("connectionreferences?`$select=$select&`$filter=" +
        [uri]::EscapeDataString("connectionreferencelogicalname eq '$nowName'")) -Token $Token).value)[0]
    if (-not $nowRow) { throw "Verification failed: no row answers to '$nowName'." }
    if ($nowRow.connectionid -ne $ConnectionId) {
        throw "Verification failed: the row reads back with connectionid '$($nowRow.connectionid)', expected '$ConnectionId'."
    }

    # Called on its own - after 4.4, say - there is no solution name in hand, so
    # read it off the action the same way the binding did.
    if (-not $Solution) { $Solution = Get-ActionSolution -BotComponentId $comp.botcomponentid -Token $Token }

    $inSolution = @(@((Invoke-Dv -Path ('solutioncomponents?$select=_solutionid_value&$filter=' +
        [uri]::EscapeDataString("objectid eq $($nowRow.connectionreferenceid)")) -Token $Token).value) | ForEach-Object {
            (Invoke-Dv -Path "solutions($($_._solutionid_value))?`$select=uniquename" -Token $Token).uniquename
        })
    if ($Solution -notin $inSolution) {
        throw "Verification failed: the connection reference is not in solution '$Solution' (only: $($inSolution -join ', ')). The published agent would not contain it."
    }

    $nowLinked = @((Invoke-Dv -Path "botcomponents($($comp.botcomponentid))?`$select=botcomponentid&`$expand=$linkNav(`$select=connectionreferenceid)" -Token $Token).$linkNav)
    if ($nowLinked.Count -ne 1 -or $nowLinked[0].connectionreferenceid -ne $nowRow.connectionreferenceid) {
        throw "Verification failed: the action is linked to $($nowLinked.Count) reference(s), expected only $($nowRow.connectionreferenceid)."
    }

    Write-Ok "$Label : action, row, connectionid and solution all agree"
}

function Publish-Agent {
    param([string] $Token)
    $filter = [uri]::EscapeDataString("schemaname eq '$Agent2SchemaName'")
    $bot = @((Invoke-Dv -Path "bots?`$select=botid,name,publishedon&`$filter=$filter" -Token $Token).value)
    if ($bot.Count -ne 1) { throw "Expected one agent with schema name '$Agent2SchemaName', found $($bot.Count)." }
    $bot = $bot[0]

    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        throw 'Power Platform CLI (pac) not found - install from https://aka.ms/PowerAppsCLI, or publish from the designer. The binding is already written.'
    }
    # Publish by GUID, not schema name: --bot takes either, but the id is already
    # in hand and it skips a name lookup that has been seen to crash pac on a
    # freshly imported agent that has never been published. pac.cmd also does not
    # propagate exit codes, so the proof of a publish is publishedon moving.
    $out = & pac copilot publish --environment $OrgUrl --bot $bot.botid 2>&1 | ForEach-Object { "$_" }
    $out | ForEach-Object { Write-Info $_ }

    $publishedon = (Invoke-Dv -Path "bots($($bot.botid))?`$select=publishedon" -Token $Token).publishedon
    if (-not $publishedon) {
        throw "Not published: $Agent2SchemaName still has no publish date. The binding is written - check 'pac auth list' or publish once from the designer."
    }
    if ($bot.publishedon -and [datetime]$publishedon -le [datetime]$bot.publishedon) {
        throw "Not published: publishedon is still $($bot.publishedon). The binding is written - check 'pac auth list'."
    }
    Write-Ok "Published at $publishedon."
}

# ==============================================================================
# 4.4  manual (Custom Entra) authentication
#
# Copilot Studio publishes no supported API for this, so everything below is
# discovery against internal endpoints, with each answer validated before use.
# The helpers are nested so they resolve $TenantId, $ClientId, $ClientSecret and
# the rest from this function's own parameters - which also keeps the plaintext
# secret scoped to this call rather than the whole script.
# ==============================================================================
function Set-Agent2ManualAuth {
    param(
        [Parameter(Mandatory)][string] $TenantId,
        [Parameter(Mandatory)][string] $ClientId,
        [Parameter(Mandatory)][string] $ClientSecret,
        [Parameter(Mandatory)][string] $DataverseUrl,
        [Parameter(Mandatory)][string] $BotName,
        [string] $SolutionUniqueName,
        [Parameter(Mandatory)][string] $ServiceProviderId,
        [Parameter(Mandatory)][string] $AuthRedirectUrl,
        [Parameter(Mandatory)][string] $ResourceUri,
        [Parameter(Mandatory)][string] $BapApiBaseUrl,
        [string] $GrantType = 'Authorization Code'
    )

    $DataverseUrl = $DataverseUrl.TrimEnd('/')

    # ---------------------------------------------------------------- plumbing
    function Read-ErrorResponseBody {
        param($Exception)
        $message = $Exception.Message
        if ($Exception.Response) {
            try { $message = "HTTP $([int]$Exception.Response.StatusCode) - $message" } catch { }
            try {
                $reader = New-Object System.IO.StreamReader($Exception.Response.GetResponseStream())
                $body   = $reader.ReadToEnd()
                if ($body) { $message = "$message`nResponse:`n$body" }
            } catch { }
        }
        $message
    }

    function Decode-JwtPayload {
        param([Parameter(Mandatory)][string] $Token)
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) { throw 'Access token does not look like a JWT.' }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        while (($payload.Length % 4) -ne 0) { $payload += '=' }
        try { return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json) }
        catch { throw 'Unable to decode access token.' }
    }

    function Normalize-Url {
        param([string] $Url)
        if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
        $Url.Trim().TrimEnd('/').ToLowerInvariant()
    }

    function Escape-ODataString { param([string] $Value) $Value.Replace("'", "''") }

    function Invoke-JsonGet {
        param(
            [Parameter(Mandatory)][string] $Uri,
            [Parameter(Mandatory)][hashtable] $Headers,
            [switch] $ReturnNullOnError
        )
        try { return Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop }
        catch {
            if ($ReturnNullOnError) { return $null }
            throw "GET failed:`n$Uri`n$(Read-ErrorResponseBody -Exception $_.Exception)"
        }
    }

    function Invoke-CopilotRequest {
        param(
            [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT')][string] $Method,
            [Parameter(Mandatory)][string] $Uri,
            [Parameter(Mandatory)][hashtable] $Headers,
            $Body,
            [switch] $ReturnNullOnError
        )
        $call = @{ Method = $Method; Uri = $Uri; Headers = $Headers; ErrorAction = 'Stop' }
        if ($null -ne $Body) {
            $call.ContentType = 'application/json'
            $call.Body        = ($Body | ConvertTo-Json -Depth 50 -Compress)
        }
        try { return Invoke-RestMethod @call }
        catch {
            if ($ReturnNullOnError) { return $null }
            throw "$Method $Uri failed:`n$(Read-ErrorResponseBody -Exception $_.Exception)"
        }
    }

    function Invoke-DataverseGet {
        param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Token)
        Invoke-JsonGet -Uri "$DataverseUrl/api/data/v9.2/$Path" -Headers @{
            Authorization      = "Bearer $Token"
            Accept             = 'application/json'
            'OData-Version'    = '4.0'
            'OData-MaxVersion' = '4.0'
        }
    }

    function Get-ParameterValue {
        param([Parameter(Mandatory)] $Parameters, [Parameter(Mandatory)][string] $Key)
        $items = @($Parameters | Where-Object { $_.key -eq $Key })
        if ($items.Count) { return $items[0].value }
        $null
    }

    function Get-GuidsFromObject {
        param($Object)
        if ($null -eq $Object) { return @() }
        $json    = $Object | ConvertTo-Json -Depth 80 -Compress
        $pattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
        $result  = New-Object System.Collections.Generic.List[string]
        foreach ($match in [regex]::Matches($json, $pattern)) {
            $value = $match.Value.ToLowerInvariant()
            if (-not $result.Contains($value)) { $result.Add($value) }
        }
        @($result)
    }

    # ------------------------------------------------------------------ tokens
    function Ensure-AzLogin {
        Write-Info 'Checking Azure CLI login...'
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI was not found. Step 4.4 needs it - install Azure CLI, or pass -SkipManualAuth.'
        }
        $currentTenant = ''
        try { $currentTenant = (& az account show --query tenantId --output tsv --only-show-errors 2>$null).Trim() }
        catch { $currentTenant = '' }
        if ($LASTEXITCODE -ne 0) { $currentTenant = '' }

        if ([string]::IsNullOrWhiteSpace($currentTenant) -or $currentTenant -ne $TenantId) {
            Write-Info "Opening az login for tenant $TenantId ..."
            & az login --tenant $TenantId --allow-no-subscriptions --only-show-errors | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
            $currentTenant = (& az account show --query tenantId --output tsv --only-show-errors).Trim()
        }
        if ($currentTenant -ne $TenantId) {
            throw "Azure CLI is logged into tenant '$currentTenant', expected '$TenantId'."
        }
        Write-Info 'Azure CLI login ready.'
    }

    function Get-AzAccessToken {
        param(
            [Parameter(Mandatory)][string] $Resource,
            [Parameter(Mandatory)][string] $Description,
            [switch] $Quiet
        )
        if (-not $Quiet) { Write-Info "Getting token for $Description..." }
        $raw = ''
        try {
            $raw = (& az account get-access-token --tenant $TenantId --resource $Resource `
                        --query accessToken --output tsv --only-show-errors 2>&1 | Out-String).Trim()
        } catch { $raw = '' }

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw) -or
            $raw -notmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.') {
            if ($Quiet) { return $null }
            throw "Could not obtain token for '$Description' resource '$Resource'. Output: $raw"
        }
        $raw
    }

    function Get-AzAccessTokenDetailed {
        param([Parameter(Mandatory)][string] $Mode, [Parameter(Mandatory)][string] $Value)
        # $azArgs, not $args - that is an automatic variable.
        $azArgs = @('account', 'get-access-token', '--tenant', $TenantId,
                    '--query', 'accessToken', '--output', 'tsv', '--only-show-errors')
        switch ($Mode) {
            'resource' { $azArgs += @('--resource', $Value) }
            'scope'    { $azArgs += @('--scope', $Value) }
            default    { throw "Unsupported token mode '$Mode'." }
        }
        $raw = ''
        try { $raw = (& az @azArgs 2>&1 | Out-String).Trim() } catch { $raw = '' }

        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($raw) -and
            $raw -match '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.') {
            return @{ Success = $true; Token = $raw; Error = $null }
        }
        @{ Success = $false; Token = $null; Error = $raw }
    }

    # --------------------------------------------------------------- discovery
    function Resolve-CopilotResource {
        Write-Info 'Discovering the Copilot Studio resource in the tenant...'
        # TSV rather than JSON for app ids: Windows PowerShell 5.1 can flatten a
        # JSON array property into one space-separated value.
        $searchNames = @('Power Virtual Agents', 'Power Virtual Agents Service', 'ccibotsprod', 'ccibots')
        $candidateAppIds = New-Object System.Collections.Generic.List[string]

        foreach ($name in $searchNames) {
            $rawIds = ''
            try { $rawIds = (& az ad sp list --display-name $name --query '[].appId' --output tsv --only-show-errors 2>$null | Out-String) }
            catch { $rawIds = '' }
            foreach ($line in ($rawIds -split "`r?`n")) {
                $appId = $line.Trim()
                if ($appId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -and
                    -not $candidateAppIds.Contains($appId)) {
                    $candidateAppIds.Add($appId)
                }
            }
        }
        if ($candidateAppIds.Count -eq 0) {
            throw 'Could not discover the Copilot Studio / Power Virtual Agents service principal in this tenant.'
        }

        $lastErrors = New-Object System.Collections.Generic.List[string]
        foreach ($appId in $candidateAppIds) {
            $spJson = ''
            try {
                $spJson = (& az ad sp show --id $appId `
                    --query '{appId:appId,displayName:displayName,servicePrincipalNames:servicePrincipalNames}' `
                    --output json --only-show-errors 2>$null | Out-String).Trim()
            } catch { $spJson = '' }
            if ([string]::IsNullOrWhiteSpace($spJson)) { continue }
            try { $sp = $spJson | ConvertFrom-Json } catch { continue }

            Write-Host "      Candidate: $($sp.displayName) [$appId]"

            $targets = New-Object System.Collections.Generic.List[string]
            $targets.Add($appId)
            foreach ($spn in @($sp.servicePrincipalNames)) {
                $value = [string]$spn
                if (-not [string]::IsNullOrWhiteSpace($value) -and -not $targets.Contains($value)) { $targets.Add($value) }
            }

            foreach ($target in $targets) {
                foreach ($attempt in @(
                    @{ Mode = 'resource'; Value = $target },
                    @{ Mode = 'scope';    Value = "$($target.TrimEnd('/'))/.default" }
                )) {
                    $result = Get-AzAccessTokenDetailed -Mode $attempt.Mode -Value $attempt.Value
                    if ($result.Success) {
                        try {
                            $claims = Decode-JwtPayload -Token $result.Token
                            # Must be a DELEGATED token in the right tenant: an
                            # app-only token (idtyp 'app') is rejected by the
                            # gateway, and so is one from another tenant.
                            if ([string]$claims.tid -eq $TenantId -and
                                -not [string]::IsNullOrWhiteSpace([string]$claims.oid) -and
                                [string]$claims.idtyp -ne 'app') {
                                Write-Ok 'Copilot delegated token acquired.'
                                Write-Host "      service principal: $($sp.displayName)"
                                Write-Host "      app id:            $appId"
                                Write-Host "      token audience:    $($claims.aud)"
                                Write-Host "      token method:      --$($attempt.Mode) $($attempt.Value)"
                                return @{ Resource = $appId; Token = $result.Token; Claims = $claims }
                            }
                        } catch { }
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace([string]$result.Error)) {
                        $lastErrors.Add("--$($attempt.Mode) $($attempt.Value) -> $($result.Error)")
                    }
                }
            }
        }

        Write-Host ''
        Write-Host '    Azure CLI could not obtain a delegated Copilot token.'
        Write-Host '    Recent Azure CLI / Entra errors:'
        foreach ($err in @($lastErrors | Select-Object -Last 8)) { Write-Host "      $err" }
        throw @'
Copilot service principals were discovered, but Azure CLI could not obtain a
usable delegated token. The errors above say whether the remaining issue is the
resource identifier, the scope, consent, or Azure CLI client authorization.

No authentication changes were made.
'@
    }

    function Resolve-Environment {
        param([Parameter(Mandatory)][string] $PowerPlatformToken)
        Write-Info 'Resolving the Power Platform environment...'
        $headers  = @{ Authorization = "Bearer $PowerPlatformToken"; Accept = 'application/json' }
        $response = Invoke-JsonGet -Headers $headers `
            -Uri 'https://api.powerplatform.com/environmentmanagement/environments?api-version=2024-10-01'

        $targetUrl = Normalize-Url $DataverseUrl
        # $envMatches, not $matches - that is an automatic variable.
        $envMatches = @($response.value | Where-Object { (Normalize-Url $_.url) -eq $targetUrl })

        if ($envMatches.Count -eq 0) {
            $domainPrefix = ([uri]$DataverseUrl).Host.Split('.')[0].ToLowerInvariant()
            $envMatches = @($response.value | Where-Object { ([string]$_.domainName).ToLowerInvariant() -eq $domainPrefix })
        }
        if ($envMatches.Count -ne 1) {
            throw "Expected one environment matching $DataverseUrl; found $($envMatches.Count)."
        }
        $envMatches[0]
    }

    function Resolve-GatewayBaseUrl {
        param(
            [Parameter(Mandatory)][string] $EnvironmentId,
            [Parameter(Mandatory)][string] $BapToken
        )
        Write-Info 'Discovering the Copilot Studio gateway...'
        $headers = @{ Authorization = "Bearer $BapToken"; Accept = 'application/json' }

        # The BAP admin environment response carries properties.runtimeEndpoints,
        # including microsoft.PowerVirtualAgents - the environment-specific PVA
        # gateway. The global BAP host handles regional routing, so no regional
        # endpoint has to be known up front.
        $listUri = "$BapApiBaseUrl/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01&`$expand=properties"
        Write-Host '      querying BAP environment metadata...'
        $listResult = Invoke-JsonGet -Uri $listUri -Headers $headers -ReturnNullOnError

        if ($listResult -and $listResult.value) {
            $environmentMatch = @($listResult.value | Where-Object {
                ([string]$_.name -eq $EnvironmentId) -or ([string]$_.id -match [regex]::Escape($EnvironmentId) + '$')
            })
            if ($environmentMatch.Count -eq 1) {
                $bapEnv = $environmentMatch[0]
                $gateway = Get-PvaEndpoint -RuntimeEndpoints $bapEnv.properties.runtimeEndpoints -Cluster $bapEnv.properties.cluster
                if ($gateway) { return $gateway }
            }
            elseif ($environmentMatch.Count -gt 1) {
                throw "BAP returned multiple records for environment '$EnvironmentId'."
            }
        }

        # The list response can be filtered or abbreviated; ask for the one
        # environment directly instead.
        Write-Host '      BAP list did not expose the gateway. Trying direct environment metadata...'
        foreach ($uri in @(
            "$BapApiBaseUrl/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId?api-version=2016-11-01",
            "$BapApiBaseUrl/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId?api-version=2020-10-01"
        )) {
            $result = Invoke-JsonGet -Uri $uri -Headers $headers -ReturnNullOnError
            if ($null -eq $result) { continue }
            $gateway = Get-PvaEndpoint -RuntimeEndpoints $result.properties.runtimeEndpoints -Cluster $result.properties.cluster
            if ($gateway) { return $gateway }
        }

        throw @'
Could not resolve the Power Virtual Agents gateway from BAP metadata.

The Copilot resource, its delegated token and the Power Platform environment all
resolved, so this is specifically the gateway lookup. No authentication changes
were made.
'@
    }

    function Get-PvaEndpoint {
        <# runtimeEndpoints first, then the cluster suffix as a fallback. #>
        param($RuntimeEndpoints, $Cluster)
        if ($RuntimeEndpoints) {
            $pva = $RuntimeEndpoints.PSObject.Properties |
                   Where-Object { $_.Name -ieq 'microsoft.PowerVirtualAgents' } |
                   Select-Object -First 1
            if ($pva -and -not [string]::IsNullOrWhiteSpace([string]$pva.Value)) {
                $gateway = ([string]$pva.Value).TrimEnd('/')
                Write-Ok "gateway resolved: $gateway"
                return $gateway
            }
        }
        $suffix = [string]$Cluster.uriSuffix
        if (-not [string]::IsNullOrWhiteSpace($suffix)) {
            $gateway = "https://powervamg.$suffix.powerapps.com"
            Write-Ok "gateway built from cluster metadata: $gateway"
            return $gateway
        }
        $null
    }

    # ----------------------------------------------------------------- headers
    function New-CopilotDiscoveryHeaders {
        param(
            [Parameter(Mandatory)][string] $Token,
            [Parameter(Mandatory)] $Claims,
            [Parameter(Mandatory)][string] $EnvironmentId,
            [Parameter(Mandatory)][string] $OrganizationId,
            [Parameter(Mandatory)][string] $CdsBotId
        )
        $headers = @{
            Authorization              = "Bearer $Token"
            Accept                     = 'application/json'
            Origin                     = 'https://copilotstudio.microsoft.com'
            Referer                    = 'https://copilotstudio.microsoft.com/'
            'x-cci-applicationsource'  = 'Web'
            'x-cci-bapenvironmentid'   = $EnvironmentId
            'x-cci-cdsbotid'           = $CdsBotId
            'x-cci-organizationid'     = $OrganizationId
            'x-cci-tenantid'           = $TenantId
            'x-ms-client-principal-id' = [string]$Claims.oid
            'x-ms-client-request-id'   = [guid]::NewGuid().ToString()
            'x-ms-client-session-id'   = [guid]::NewGuid().ToString()
            'x-ms-client-tenant-id'    = [string]$Claims.tid
        }
        # Without this the change lands in the Default solution only.
        if (-not [string]::IsNullOrWhiteSpace($SolutionUniqueName)) {
            $headers['x-ms-solution-unique-name'] = $SolutionUniqueName
        }
        $headers
    }

    function New-CopilotBotHeaders {
        param(
            [Parameter(Mandatory)][string] $Token,
            [Parameter(Mandatory)] $Claims,
            [Parameter(Mandatory)][string] $EnvironmentId,
            [Parameter(Mandatory)][string] $OrganizationId,
            [Parameter(Mandatory)][string] $CdsBotId,
            [Parameter(Mandatory)][string] $InternalBotId
        )
        $headers = New-CopilotDiscoveryHeaders -Token $Token -Claims $Claims `
            -EnvironmentId $EnvironmentId -OrganizationId $OrganizationId -CdsBotId $CdsBotId
        $headers['x-cci-botid']         = $InternalBotId
        $headers['x-cci-routing-botid'] = $InternalBotId
        $headers
    }

    # --------------------------------------------------- internal routing bot id
    function Test-InternalBotId {
        param(
            [Parameter(Mandatory)][string] $Candidate,
            [Parameter(Mandatory)][string] $GatewayBaseUrl,
            [Parameter(Mandatory)][string] $CopilotToken,
            [Parameter(Mandatory)] $CopilotClaims,
            [Parameter(Mandatory)][string] $EnvironmentId,
            [Parameter(Mandatory)][string] $OrganizationId,
            [Parameter(Mandatory)][string] $CdsBotId
        )
        $headers = New-CopilotBotHeaders -Token $CopilotToken -Claims $CopilotClaims `
            -EnvironmentId $EnvironmentId -OrganizationId $OrganizationId `
            -CdsBotId $CdsBotId -InternalBotId $Candidate

        $result = Invoke-CopilotRequest -Method GET -Headers $headers -ReturnNullOnError `
            -Uri "$GatewayBaseUrl/api/botmanagement/v1/channels/authentication/connections/configuration"

        if ($result -and -not [string]::IsNullOrWhiteSpace([string]$result.etag)) {
            return @{ InternalBotId = $Candidate; Headers = $headers; Configuration = $result }
        }
        $null
    }

    function Resolve-InternalBotId {
        param(
            [Parameter(Mandatory)][string] $GatewayBaseUrl,
            [Parameter(Mandatory)][string] $CopilotToken,
            [Parameter(Mandatory)] $CopilotClaims,
            [Parameter(Mandatory)][string] $EnvironmentId,
            [Parameter(Mandatory)][string] $OrganizationId,
            [Parameter(Mandatory)][string] $CdsBotId,
            [Parameter(Mandatory)] $DataverseBot
        )
        Write-Info 'Discovering the Copilot internal/routing bot id...'
        $configurationUri = "$GatewayBaseUrl/api/botmanagement/v1/channels/authentication/connections/configuration"

        $discoveryHeaders = New-CopilotDiscoveryHeaders -Token $CopilotToken -Claims $CopilotClaims `
            -EnvironmentId $EnvironmentId -OrganizationId $OrganizationId -CdsBotId $CdsBotId

        # Some environments resolve the bot without x-cci-botid at all.
        $withoutInternal = Invoke-CopilotRequest -Method GET -Uri $configurationUri `
            -Headers $discoveryHeaders -ReturnNullOnError
        if ($withoutInternal -and -not [string]::IsNullOrWhiteSpace([string]$withoutInternal.etag)) {
            Write-Ok 'internal routing header is not required for this environment.'
            return @{ InternalBotId = $null; Headers = $discoveryHeaders; Configuration = $withoutInternal }
        }

        # Every GUID we already know is NOT the routing id, so exclude them and
        # try what is left.
        $known = @(
            $EnvironmentId.ToLowerInvariant(), $OrganizationId.ToLowerInvariant(),
            $CdsBotId.ToLowerInvariant(), $TenantId.ToLowerInvariant(),
            $ClientId.ToLowerInvariant(), ([string]$CopilotClaims.oid).ToLowerInvariant()
        )
        $candidateIds = New-Object System.Collections.Generic.List[string]
        foreach ($guid in (Get-GuidsFromObject -Object $DataverseBot)) {
            if (-not $known.Contains($guid) -and -not $candidateIds.Contains($guid)) { $candidateIds.Add($guid) }
        }

        # Bot metadata routes that can expose the routing id. This surface is not
        # publicly documented, so every result is validated before being used.
        foreach ($uri in @(
            "$GatewayBaseUrl/api/botmanagement/v1/bots?environmentId=$EnvironmentId",
            "$GatewayBaseUrl/api/botmanagement/v1/environments/$EnvironmentId/bots",
            "$GatewayBaseUrl/api/botmanagement/v1/environments/$EnvironmentId/bots/$CdsBotId",
            "$GatewayBaseUrl/api/botauthoring/v1/environments/$EnvironmentId/bots",
            "$GatewayBaseUrl/api/botauthoring/v1/environments/$EnvironmentId/bots/$CdsBotId",
            "$GatewayBaseUrl/api/botmanagement/v1/bots/$CdsBotId"
        )) {
            Write-Host "      probing: $uri"
            $response = Invoke-CopilotRequest -Method GET -Uri $uri -Headers $discoveryHeaders -ReturnNullOnError
            if ($null -eq $response) { continue }
            foreach ($guid in (Get-GuidsFromObject -Object $response)) {
                if (-not $known.Contains($guid) -and -not $candidateIds.Contains($guid)) { $candidateIds.Add($guid) }
            }
        }

        Write-Host "      candidate routing GUIDs found: $($candidateIds.Count)"
        foreach ($candidate in $candidateIds) {
            Write-Host "      validating: $candidate"
            $validated = Test-InternalBotId -Candidate $candidate -GatewayBaseUrl $GatewayBaseUrl `
                -CopilotToken $CopilotToken -CopilotClaims $CopilotClaims `
                -EnvironmentId $EnvironmentId -OrganizationId $OrganizationId -CdsBotId $CdsBotId
            if ($validated) { Write-Ok "internal bot id resolved: $candidate"; return $validated }
        }

        throw @'
Automatic internal-bot-id discovery found no candidate that Copilot Studio
accepts. The gateway and Copilot resource were both resolved, so the remaining
unknown is which bot metadata endpoint this tenant uses for x-cci-botid.

No authentication changes were made.
'@
    }

    # ---------------------------------------------------------------- payloads
    function New-CreateConfigurationPayload {
        param([Parameter(Mandatory)][string] $Etag)
        @{
            authenticationMode = 'CustomAzureActiveDirectory'
            authenticationConnection = @{
                serviceProviderId = $ServiceProviderId
                scopes            = ''
                parameters = @(
                    @{ key = 'tenantId';     value = $TenantId },
                    @{ key = 'clientSecret'; value = $ClientSecret },
                    @{ key = 'clientId';     value = $ClientId },
                    @{ key = 'grantType';    value = $GrantType },
                    @{ key = 'loginUrl';     value = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize" },
                    @{ key = 'resourceUri';  value = $ResourceUri }
                )
                serviceProviderDisplayName = 'Microsoft Entra ID'
                clientSecret               = $ClientSecret
                clientId                   = $ClientId
            }
            etag            = $Etag
            authRedirectUrl = $AuthRedirectUrl
        }
    }

    function New-UpdateConfigurationPayload {
        param([Parameter(Mandatory)] $Current)
        $connection = $Current.authenticationConnection
        if ($null -eq $connection) { throw 'Update requested but authenticationConnection is null.' }

        $existingName      = [string]$connection.name
        $existingSettingId = [string]$connection.settingId
        if ([string]::IsNullOrWhiteSpace($existingName) -or $existingName.Trim().Length -lt 2) {
            throw 'Update requested but the existing authentication connection has no valid connection name. Use CREATE instead.'
        }
        if ([string]::IsNullOrWhiteSpace($existingSettingId)) {
            throw 'Update requested but the existing authentication connection has no Setting ID. Use CREATE instead.'
        }

        @{
            authenticationMode = 'CustomAzureActiveDirectory'
            authenticationConnection = @{
                name                       = $existingName
                clientId                   = $ClientId
                settingId                  = $existingSettingId
                clientSecret               = $ClientSecret
                scopes                     = $null
                serviceProviderId          = $ServiceProviderId
                serviceProviderDisplayName = 'Azure Active Directory'
                clientCertificateUrl       = $null
                isx5cRequired              = $null
                uniqueIdentifier           = $null
                parameters = @(
                    @{ key = 'tenantId';     value = $TenantId },
                    @{ key = 'clientSecret'; value = $ClientSecret },
                    @{ key = 'clientId';     value = $ClientId },
                    @{ key = 'grantType';    value = $GrantType },
                    @{ key = 'loginUrl';     value = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize" },
                    @{ key = 'resourceUri';  value = $ResourceUri },
                    @{ key = 'scopes';       value = $null }
                )
            }
            etag            = [string]$Current.etag
            authRedirectUrl = $AuthRedirectUrl
        }
    }

    # -------------------------------------------------------------------- main
    Write-Info "tenant      $TenantId"
    Write-Info "environment $DataverseUrl"
    Write-Info "agent       $BotName"

    Ensure-AzLogin

    $dataverseToken     = Get-AzAccessToken -Resource $DataverseUrl                      -Description 'Dataverse'
    $powerPlatformToken = Get-AzAccessToken -Resource 'https://api.powerplatform.com/'   -Description 'Power Platform API'
    $bapToken           = Get-AzAccessToken -Resource "$BapApiBaseUrl/"                  -Description 'Business Application Platform API'

    $copilot       = Resolve-CopilotResource
    $copilotToken  = [string]$copilot.Token
    $copilotClaims = $copilot.Claims

    $environment    = Resolve-Environment -PowerPlatformToken $powerPlatformToken
    $environmentId  = [string]$environment.id
    $organizationId = [string]$environment.dataverseId
    if ([string]::IsNullOrWhiteSpace($environmentId) -or [string]::IsNullOrWhiteSpace($organizationId)) {
        throw 'Environment or Dataverse organization id could not be resolved.'
    }
    Write-Info "environment id  $environmentId"
    Write-Info "organization id $organizationId"
    Write-Info "display name    $($environment.displayName)"

    $gatewayBaseUrl = Resolve-GatewayBaseUrl -EnvironmentId $environmentId -BapToken $bapToken

    Write-Info "Finding the Dataverse bot '$BotName'..."
    $filter = [uri]::EscapeDataString("name eq '$(Escape-ODataString $BotName)'")
    $bots = @((Invoke-DataverseGet -Token $dataverseToken -Path (
        'bots?$select=botid,name,schemaname,componentidunique,authenticationconfiguration,' +
        'authenticationmode,authenticationtrigger,configuration,applicationmanifestinformation,' +
        "synchronizationstatus&`$filter=$filter")).value)

    if ($bots.Count -eq 0) { throw "Agent '$BotName' was not found. This is the DISPLAY name, not the schema name." }
    if ($bots.Count -gt 1) { throw "Multiple agents named '$BotName' were found." }
    $bot      = $bots[0]
    $cdsBotId = [string]$bot.botid
    Write-Info "cds bot id  $cdsBotId  (schema $($bot.schemaname))"

    $routing = Resolve-InternalBotId -GatewayBaseUrl $gatewayBaseUrl -CopilotToken $copilotToken `
        -CopilotClaims $copilotClaims -EnvironmentId $environmentId `
        -OrganizationId $organizationId -CdsBotId $cdsBotId -DataverseBot $bot

    $headers = $routing.Headers
    $current = $routing.Configuration
    Write-Ok "discovery complete (gateway $gatewayBaseUrl)"
    Write-Info "current mode    $($current.authenticationMode)"

    # Some environments return a partial authenticationConnection even when no
    # usable connection exists yet - an empty name or settingId. That is a
    # CREATE, not an UPDATE: a PUT with an invalid connection name fails.
    $existingConnection = $current.authenticationConnection
    $existingName       = if ($null -ne $existingConnection) { [string]$existingConnection.name }      else { '' }
    $existingSettingId  = if ($null -ne $existingConnection) { [string]$existingConnection.settingId } else { '' }

    $isCreate = ($null -eq $existingConnection) -or
                [string]::IsNullOrWhiteSpace($existingName) -or
                ($existingName.Trim().Length -lt 2) -or
                [string]::IsNullOrWhiteSpace($existingSettingId)

    if ($isCreate) {
        Write-Info 'Creating manual Entra authentication...'
        $method  = 'POST'
        $payload = New-CreateConfigurationPayload -Etag ([string]$current.etag)
    } else {
        Write-Info "Updating manual Entra authentication (connection '$existingName')..."
        $method  = 'PUT'
        $payload = New-UpdateConfigurationPayload -Current $current
    }

    $configurationUri = "$gatewayBaseUrl/api/botmanagement/v1/channels/authentication/connections/configuration"
    $configResult = Invoke-CopilotRequest -Method $method -Uri $configurationUri -Headers $headers -Body $payload
    if ($null -eq $configResult -or
        [string]::IsNullOrWhiteSpace([string]$configResult.authenticationConnection.name) -or
        [string]::IsNullOrWhiteSpace([string]$configResult.etag)) {
        throw 'Authentication configuration response is incomplete.'
    }
    Write-Ok "$method configuration succeeded (connection $($configResult.authenticationConnection.name))"

    # Trigger and access policy, which are separate from the connection itself.
    Invoke-CopilotRequest -Method POST -Headers $headers `
        -Uri "$gatewayBaseUrl/api/botauthoring/v1/environments/$environmentId/bots/$cdsBotId/auth/authorization" `
        -Body @{
            authenticationTrigger = 'Always'
            accessControlPolicy   = 'Any'
            etag                  = [string]$configResult.etag
        } | Out-Null
    Write-Ok 'authorization settings applied.'

    # Read it back rather than trusting the write.
    $verify = Invoke-CopilotRequest -Method GET -Uri $configurationUri -Headers $headers
    $verifiedTenantId = Get-ParameterValue -Parameters $verify.authenticationConnection.parameters -Key 'tenantId'

    if ([string]$verify.authenticationMode -ne 'CustomAzureActiveDirectory') {
        throw "Verification failed: authentication mode is '$($verify.authenticationMode)', expected CustomAzureActiveDirectory."
    }
    if ([string]$verify.authenticationConnection.clientId -ne $ClientId) {
        throw 'Verification failed: client id mismatch.'
    }
    if ([string]$verifiedTenantId -ne $TenantId) {
        throw 'Verification failed: tenant id mismatch.'
    }

    Write-Ok "manual authentication set: $($verify.authenticationMode)"
    Write-Info "connection name $($verify.authenticationConnection.name)"
    Write-Info "setting id      $($verify.authenticationConnection.settingId)"
}

# ==============================================================================
# main
# ==============================================================================
try {
    Write-Stage 'Step 2 - Machine setup and CUA configuration'

    # --- collect every input up front, so nothing prompts mid-run -------------
    $OrgUrl = ConvertTo-OrgUrl (Read-RequiredValue 'Target Dataverse org URL (https://org....crm.dynamics.com)' (Get-Fallback $OrgUrl 'OrgUrl'))
    if (-not $OrgUrl) { throw 'Could not read -OrgUrl as an org URL.' }

    $needsRegistration = -not $SkipRegistration
    $needsConnection   = -not $SkipConnection
    $needsBinding      = -not $SkipBinding

    if ($needsRegistration -or $needsConnection) {
        $EnvironmentId = Read-RequiredGuid 'Power Platform environment GUID' (Get-Fallback $EnvironmentId 'EnvironmentId')
    }
    $TenantId = Read-RequiredGuid 'Tenant id' (Get-Fallback $TenantId 'TenantId')

    if ($needsRegistration) {
        $ApplicationId = Read-RequiredGuid  'Machine-registration app (client) id' (Get-Fallback $ApplicationId 'ApplicationId')
        $ClientSecret  = Read-RequiredSecret 'Machine-registration app client secret' $ClientSecret
    }

    if (-not $ConnectionName) { $ConnectionName = Get-Fallback $ConnectionName 'ConnectionName' }
    if (-not $ConnectionName) { $ConnectionName = "$MachineName-CUA" }

    if ($needsConnection) {
        $MachineUsername = Read-RequiredValue  "Windows username that signs in to $MachineName" (Get-Fallback $MachineUsername 'MachineUsername')
        $MachinePassword = Read-RequiredSecret 'Windows password' $MachinePassword
    }
    if ($needsBinding) {
        $Agent2CuaComponentSchema = Read-RequiredValue 'Agent 2 Computer Use action schema (e.g. cr720_Agent2UITesting.action.Computeruse-Computeruse)' (Get-Fallback $Agent2CuaComponentSchema 'Agent2CuaComponentSchema')
    }
    if ($PublishNow) {
        $Agent2SchemaName = Read-RequiredValue 'Agent 2 schema name (schema name, NOT display name)' (Get-Fallback $Agent2SchemaName 'Agent2SchemaName')
    }
    if (-not $SkipManualAuth) {
        $Agent2DisplayName = Read-RequiredValue  "Agent 2 DISPLAY name as shown in Copilot Studio (e.g. 'Agent 2 UI Testing')" (Get-Fallback $Agent2DisplayName 'Agent2DisplayName')
        $AuthClientId      = Read-RequiredGuid   'Agent authentication app (client) id' (Get-Fallback $AuthClientId 'AuthClientId')
        $AuthClientSecret  = Read-RequiredSecret 'Agent authentication app client secret' $AuthClientSecret
        if (-not $AuthTenantId)       { $AuthTenantId       = Get-Fallback $AuthTenantId 'AuthTenantId' }
        if (-not $AuthTenantId)       { $AuthTenantId       = $TenantId }
        if (-not $SolutionUniqueName) { $SolutionUniqueName = $State.SolutionUniqueName }
    }

    Write-Info "org         $OrgUrl"
    Write-Info "environment $EnvironmentId"
    Write-Info "machine     $MachineName"
    Write-Info "connection  $ConnectionName"

    # ==========================================================================
    # 3.1  preflight and install
    # ==========================================================================
    $groupId = $null

    if ($SkipRegistration) {
        Write-Stage '3.1  Install and registration (skipped)'
        $local = Get-LocalRegistration
        if ($local) { $groupId = $local.GroupId }
    }
    else {
        Write-Stage '3.1  Preflight'
        Assert-Admin
        Test-WindowsEdition
        Test-Connectivity

        # Is this box already registered? Answered from the local record, so it
        # costs nothing and happens before anything is downloaded.
        $local = Get-LocalRegistration
        $alreadyRegistered = $false
        if ($local -and -not $Force) {
            Write-Info "Already registered: machine $($local.MachineId)"
            Write-Info "Org: $($local.OrgUrl)"
            Write-Info "Machine group: $(if ($local.GroupId) { $local.GroupId } else { '(none recorded)' })"
            Write-Info 'Skipping registration. Re-run with -Force to register again - that breaks existing connections.'
            $alreadyRegistered = $true
            $groupId = $local.GroupId
        }

        if ($SkipInstall) { Write-Info 'Install skipped (-SkipInstall).' }
        else {
            Write-Stage '3.1  Install Power Automate for desktop'
            Install-Pad
        }

        if (-not $alreadyRegistered) {
            Write-Stage "3.1  Register '$MachineName' to environment $EnvironmentId"
            if (-not (Test-Path $RegExe)) {
                throw "$RegExe not found. Power Automate must be installed before the machine can be registered - re-run without -SkipInstall."
            }
            $plain = ConvertFrom-Secure $ClientSecret
            try     { Register-Machine -Secret $plain }
            finally { $plain = $null }
            Confirm-Runtime
            # The machine group id only exists locally once registration has run.
            $local   = Get-LocalRegistration
            $groupId = if ($local) { $local.GroupId } else { $null }
        }

        Enable-BrowserExtensions
    }

    # ==========================================================================
    # 3.2  enable the machine group for computer use
    # ==========================================================================
    if ($SkipRegistration -and $SkipComputerUse) {
        Write-Stage '3.2  Computer use (skipped)'
    } else {
        Write-Stage '3.2  Enable the machine for computer use'
        if (-not $ApplicationId) {
            $ApplicationId = Read-RequiredGuid 'App (client) id for the Dataverse call' (Get-Fallback $ApplicationId 'ApplicationId')
        }
        if (-not $ClientSecret) { $ClientSecret = Read-RequiredSecret 'That app''s client secret' $ClientSecret }

        $plain = ConvertFrom-Secure $ClientSecret
        try     { $appToken = Get-AppOnlyToken -Resource $OrgUrl -Secret $plain }
        finally { $plain = $null }
        Write-Info "Authenticated to $OrgUrl (app-only)"
        $groupId = Enable-ComputerUse -Token $appToken -GroupId $groupId
    }

    # --- gate -----------------------------------------------------------------
    Write-Stage 'Gate - machine registered and grouped'
    if (-not $groupId) {
        throw 'No machine group id, so there is nothing for the Computer Use connection to bind to. Re-run with -Force to register this machine from scratch.'
    }
    Write-Ok "machine group $groupId"
    Write-Gate "Confirm '$MachineName' shows Online under Power Automate -> Monitor -> Machines."

    # ==========================================================================
    # 3.3  create the Computer Use connection
    # ==========================================================================
    Write-Stage '3.3  Computer Use connection'
    # Delegated from here on: a service principal cannot create or own one of
    # these connections (code 10006), whatever Dataverse role it holds.
    $paToken = Get-DelegatedToken -Resource $PowerAppsScope
    $dvToken = Get-DelegatedToken -Resource $OrgUrl
    Write-Info 'Authenticated for the Power Apps and Dataverse APIs (delegated)'

    if ($SkipConnection) {
        $connectionId = Get-CuaConnectionId -PowerAppsToken $paToken -Name $ConnectionName
        Write-Info "Using the existing connection '$ConnectionName' -> $connectionId"
    } else {
        $plain = ConvertFrom-Secure $MachinePassword
        try {
            $connectionId = New-CuaConnection -PowerAppsToken $paToken -GroupId $groupId `
                                              -Username $MachineUsername -Password $plain
        }
        finally { $plain = $null }
    }

    # ==========================================================================
    # 4.1 - 4.3  bind the connection into Agent 2's Computer Use action
    # ==========================================================================
    if ($SkipBinding) {
        Write-Stage '4.1  Agent binding (skipped)'
    } else {
        Write-Stage '4.1  Bind the connection into Agent 2'
        Set-AgentBinding -Token $dvToken -ConnectionId $connectionId
    }

    # ==========================================================================
    # 4.4  manual (Custom Entra) authentication
    # ==========================================================================
    if ($SkipManualAuth) {
        Write-Stage '4.4  Manual authentication (skipped)'
        Write-Info 'Agent 2 keeps whatever authentication the imported solution set.'
    } else {
        Write-Stage '4.4  Configure Agent 2 manual authentication'
        $plain = ConvertFrom-Secure $AuthClientSecret
        try {
            Set-Agent2ManualAuth -TenantId $AuthTenantId -ClientId $AuthClientId -ClientSecret $plain `
                -DataverseUrl $OrgUrl -BotName $Agent2DisplayName -SolutionUniqueName $SolutionUniqueName `
                -ServiceProviderId $ServiceProviderId -AuthRedirectUrl $AuthRedirectUrl `
                -ResourceUri $AuthResourceUri -BapApiBaseUrl $BapApiBaseUrl
        }
        finally { $plain = $null }

        # Changing an agent's authentication mode can discard its connections -
        # switching OFF Custom Entra is known to. Setting it TO Custom Entra
        # should not, but one call turns a silent breakage into an error.
        if (-not $SkipBinding) {
            Write-Stage 'Gate - binding survived the authentication change'
            Test-AgentBinding -Token $dvToken -ConnectionId $connectionId -Label 're-verified'
        }
    }

    if ($PublishNow -and -not $SkipBinding) {
        Write-Stage "4.5  Publishing $Agent2SchemaName"
        Publish-Agent -Token $dvToken
    }

    Save-State @{
        OrgUrl                   = $OrgUrl
        EnvironmentId            = $EnvironmentId
        TenantId                 = $TenantId
        ApplicationId            = $ApplicationId
        MachineName              = $MachineName
        MachineGroupId           = $groupId
        ConnectionName           = $ConnectionName
        ConnectionId             = $connectionId
        MachineUsername          = $MachineUsername
        Agent2SchemaName         = $Agent2SchemaName
        Agent2CuaComponentSchema = $Agent2CuaComponentSchema
        Agent2DisplayName        = $Agent2DisplayName
        AuthClientId             = $AuthClientId
        AuthTenantId             = $AuthTenantId
        SolutionUniqueName       = $SolutionUniqueName
    }

    Write-Stage 'Step 2 complete'
    if (-not $PublishNow) {
        Write-Info 'Agent 2 is bound but NOT published - nothing above reaches the runtime yet.'
    }
    Write-Info 'Next: .\Share-Agents.ps1'
}
catch {
    Write-Host "`nSTEP 2 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
