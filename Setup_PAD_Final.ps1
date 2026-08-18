<#
.SYNOPSIS
  Install Power Automate for desktop AND register the machine to a Power Platform
  environment, in one pass. Merge of install_PAD.ps1 (part 1) and Register_PAD.ps1
  (part 2), which remain usable on their own.

.DESCRIPTION
  Steps:
    1. Preflight - administrator rights, Windows edition, outbound connectivity,
       credential present.
    2. Download and silently install Power Automate for desktop, including the
       machine-runtime app and browser extensions.
    3. Register the machine to the environment, and verify the machine-runtime
       service is running. This is what makes it appear in Power Automate; there
       is no agentless path and the PAD GUI is never launched.
       Optional - see -Register. Skipped when -OrgUrl shows the machine is
       already connected, unless -Force.
    4. Optionally enable the machine for computer use - see -EnableComputerUse.
    5. Force-install the Power Automate extension in Chrome and Edge via machine policy,
       so it is enabled and the user cannot turn it off.

  Authentication is by Microsoft Entra app registration only:

    PAD.MachineRegistration.Silent.exe -register -applicationid <app-id>
        -clientsecret -tenantid <tenant-id> -environmentid <env-id>
        -machinename <machine-name> -machinedescription CUA

  The app needs Microsoft Flow Service permissions with admin consent, and an
  application user in the target environment. See README.md.

  Note that -clientsecret takes no value on the command line. The secret comes
  from the PAD_SECRET environment variable, or is asked for with masked input if
  that is unset, and is piped over stdin - never placed on the command line,
  where it would be visible in the process list.

  Nothing about the environment, tenant or app registration is asked for unless
  you choose to register. An install-and-extension run needs no parameters at all.

  IMPORTANT: never clone a VM after this script has run. The registration and
  machine identity will break. Keep the base image clean and run this post-clone
  on each machine.

.PARAMETER EnvironmentId
  The Power Platform environment GUID. Found in the Power Automate portal URL.
  Asked for if registering and not supplied.

.PARAMETER ApplicationId
  Application (client) ID of the Entra app registration.
  Asked for if registering and not supplied.

.PARAMETER TenantId
  Directory (tenant) ID. Asked for if registering and not supplied.

.PARAMETER EnableComputerUse
  After registering, enable the machine for computer use, which otherwise has to
  be toggled by hand in the portal. This is the usagetype column on the machine's
  GROUP (flowmachinegroups), set over the Dataverse Web API - so it applies to
  every machine in that group. The column is not in Microsoft's published schema
  reference, so the step fails soft: a failure warns and prints the manual
  fallback, and never fails the run.

.PARAMETER OrgUrl
  Dataverse org URL, e.g. https://orgc0ee9ebb.crm.dynamics.com
  Required only with -EnableComputerUse. Asked for if not supplied.

.EXAMPLE
  # Interactive: choose whether to register, and be asked for the details.
  .\Setup_PAD_Final.ps1

.EXAMPLE
  # Install and browser extensions only, no prompts, no registration details.
  .\Setup_PAD_Final.ps1 -Register No

.EXAMPLE
  # Unattended registration.
  $env:PAD_SECRET = '<client secret>'
  .\Setup_PAD_Final.ps1 -Register Yes `
      -EnvironmentId '20bbbb76-91c1-efde-bf32-8a5468336104' `
      -ApplicationId '<app client id>' `
      -TenantId      'edda99bb-bab6-4c4c-8aa1-4b99e8e09c1b' `
      -MachineName   'CUA-UAT-01'

.EXAMPLE
  # Register and enable for computer use, no portal interaction at all.
  $env:PAD_SECRET = '<client secret>'
  .\Setup_PAD_Final.ps1 -Register Yes -EnableComputerUse `
      -OrgUrl        'https://orgc0ee9ebb.crm.dynamics.com' `
      -EnvironmentId '20bbbb76-91c1-efde-bf32-8a5468336104' `
      -ApplicationId '<app client id>' `
      -TenantId      'edda99bb-bab6-4c4c-8aa1-4b99e8e09c1b'

.OUTPUTS
  Exit code 0 on success, 1 on failure.
#>

[CmdletBinding()]
param(
    # Registration details. Optional on the command line - they are asked for
    # only if you choose to register, so an install-and-extension run needs none
    # of them. Supplying them up front skips the prompts.
    [string]$EnvironmentId,
    [string]$ApplicationId,
    [string]$TenantId,

    [string]$MachineName        = $env:COMPUTERNAME,
    [string]$MachineDescription = 'CUA',

    # Verify the current download link from the Power Automate install docs.
    [string]$InstallerUrl = 'https://go.microsoft.com/fwlink/?linkid=2102613',

    [string]$WorkDir = "$env:TEMP\pad-install",

    # Skip the network reachability probe (e.g. when a proxy blocks ICMP/TCP tests
    # but traffic is actually allowed).
    [switch]$SkipConnectivityCheck,

    # Whether to connect this machine to the environment.
    #   Ask - prompt (default, interactive runs)
    #   Yes - register without prompting (unattended provisioning)
    #   No  - skip registration, do the install and browser extensions only
    [ValidateSet('Ask', 'Yes', 'No')]
    [string]$Register = 'Ask',

    # Microsoft Power Automate extension IDs, PAD v2.27 or later.
    # Legacy (v2.26 or earlier) are gjgfobnenmnljakmhboildkafdkicala for Chrome
    # and njjljiblognghfjfpcdpdbpbfcmhgafg for Edge.
    [string]$ChromeExtensionId = 'ljglajjnnkapghbckkcmodicjhacbfhk',
    [string]$EdgeExtensionId   = 'kagpabjoboikccfdghpdlaaopmgpgfdc',

    # Leave browser policy alone (e.g. already deployed by GPO).
    [switch]$SkipChromeExtension,
    [switch]$SkipEdgeExtension,

    # Enable the machine for computer use after registration.
    [switch]$EnableComputerUse,

    # Dataverse org URL, e.g. https://orgc0ee9ebb.crm.dynamics.com
    # Required only when -EnableComputerUse is specified.
    [string]$OrgUrl,

    # Reinstall even if Power Automate is already present. Without this the
    # install step is skipped whenever the registration tool is found on disk.
    [switch]$Reinstall,

    # Override an existing registration. This breaks existing connections to the
    # machine. Does not trigger a reinstall.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$PadRoot = "${env:ProgramFiles(x86)}\Power Automate Desktop"
$RegExe  = Join-Path $PadRoot 'PAD.MachineRegistration.Silent.exe'

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Info { param([string]$m) Write-Host "    $m" }

# ----------------------------- preflight -----------------------------

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run as Administrator. Admin permissions are required to install Power Automate for desktop.'
    }
    Write-Info 'Running as Administrator.'
}

function Test-WindowsEdition {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Info "OS: $($os.Caption) ($($os.Version))"
    if ($os.Caption -match 'Home') {
        throw 'Direct connectivity is not available on Windows 10 Home or Windows 11 Home. Use Pro, Enterprise, or Server.'
    }
}

function Test-Connectivity {
    if ($SkipConnectivityCheck) {
        Write-Info 'Connectivity check skipped.'
        return
    }
    # The machine runtime connects OUTBOUND to the Power Automate cloud services.
    # Blocked endpoints surface later as a generic "error connecting to the
    # Power Automate cloud services" during registration.
    $endpoints = @(
        'login.microsoftonline.com',
        'gateway.prod.island.powerapps.com',
        'go.microsoft.com'
    )
    foreach ($h in $endpoints) {
        $ok = Test-NetConnection -ComputerName $h -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($ok) { Write-Info "$h`:443 reachable" }
        else {
            Write-Warning "$h`:443 UNREACHABLE. Machine connectivity requires *.dynamics.com, *.servicebus.windows.net, and *.gateway.prod.island.powerapps.com to be allowed through the proxy/firewall."
        }
    }
}

function Confirm-Registration {
    <#
      Returns $true to register the machine, $false to skip straight to the
      browser extension step. -Register Yes/No answers this without prompting,
      which is what unattended provisioning should pass.
    #>
    if ($Register -eq 'Yes') { Write-Info 'Registration: yes (-Register Yes).'; return $true }
    if ($Register -eq 'No')  { Write-Info 'Registration: skipped (-Register No).'; return $false }

    Write-Step 'Connect this machine to Power Platform?'
    Write-Info "Machine name: $MachineName"
    if ($EnvironmentId) { Write-Info "Environment : $EnvironmentId" }
    Write-Host ''
    Write-Host '    [1] Yes - register this machine now'
    Write-Host '    [2] No  - skip registration, continue to the browser extensions'
    Write-Host ''

    # Read-Host against a redirected/empty stdin returns '' forever, so cap the
    # attempts rather than spinning. Non-interactive callers should pass -Register.
    foreach ($attempt in 1..3) {
        $choice = (Read-Host '    Choice (1/2)').Trim()
        switch ($choice) {
            '1' { return $true }
            '2' { return $false }
            default { Write-Host '    Enter 1 or 2.' -ForegroundColor Yellow }
        }
    }
    throw 'No valid choice given. Re-run with -Register Yes or -Register No.'
}

function Read-RequiredGuid {
    <# Return $Current if it is a usable GUID, otherwise ask for one. #>
    param([string]$Label, [string]$Current)

    if ($Current) {
        if ($Current -as [guid]) { return $Current }
        throw "-$Label is not a valid GUID: '$Current'"
    }
    foreach ($attempt in 1..3) {
        $value = (Read-Host "    $Label").Trim()
        if ($value -as [guid]) { return $value }
        Write-Host '    Not a valid GUID.' -ForegroundColor Yellow
    }
    throw "No valid $Label given. Pass it as a parameter instead."
}

function ConvertTo-OrgUrl {
    <#
      Normalise anything org-shaped to https://<org>.crm.dynamics.com:
        orgc0ee9ebb.crm.dynamics.com          -> adds the scheme
        https://orgc0ee9ebb.api.crm.../       -> drops 'api.' and the trailing /
      The registry stores the .api. host, but the token scope and the Web API
      both want the plain org host. Returns $null if it is not org-shaped.
    #>
    param([string]$Value)

    if (-not $Value) { return $null }
    $v = $Value.Trim()
    if ($v -notmatch '^[a-z]+://') { $v = "https://$v" }      # bare hostname
    $uri = $v -as [uri]
    if (-not $uri -or $uri.Scheme -ne 'https' -or -not $uri.Host) { return $null }
    return "https://$($uri.Host -replace '\.api\.', '.')"
}

function Read-RequiredOrgUrl {
    <# Same shape as Read-RequiredGuid, for the Dataverse org URL. #>
    param([string]$Label, [string]$Current)

    if ($Current) {
        $norm = ConvertTo-OrgUrl $Current
        if ($norm) { return $norm }
        throw "-$Label is not a usable org URL: '$Current'"
    }
    foreach ($attempt in 1..3) {
        $value = Read-Host "    $Label (e.g. orgc0ee9ebb.crm.dynamics.com)"
        $norm  = ConvertTo-OrgUrl $value
        if ($norm) { return $norm }
        Write-Host '    Not a usable org URL.' -ForegroundColor Yellow
    }
    throw "No valid $Label given. Pass it as a parameter instead."
}

function Get-LocalRegistration {
    <#
      Power Automate records its own registration under HKLM. This is the
      authoritative answer to "is THIS box registered", and needs no credentials
      and no network - unlike asking Dataverse, which can only match on machine
      name and cannot tell two same-named machines apart.

      GroupIds is the machine group the computer-use flag lives on, so this also
      removes the group lookup entirely.
    #>
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Power Automate Desktop\Registration',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Power Automate Desktop\Registration'
    )
    foreach ($key in $keys) {
        if (-not (Test-Path $key)) { continue }
        $r = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $r -or $r.RegistrationState -ne 'Registered') { continue }
        return [pscustomobject]@{
            MachineId = $r.MachineId
            # Comma-separated in principle; a machine belongs to one group here.
            GroupId   = ($r.GroupIds -split ',' | Where-Object { $_ } | Select-Object -First 1).Trim()
            OrgUrl    = ConvertTo-OrgUrl $r.OrgUri
            TenantId  = $r.TenantId
            Key       = $key
        }
    }
    return $null
}

function Read-RegistrationDetails {
    <#
      Asked for only once registration is chosen. Anything already supplied on
      the command line is validated and kept, so unattended runs never prompt.
    #>
    Write-Step 'Registration details'
    $script:EnvironmentId = Read-RequiredGuid 'EnvironmentId'  $EnvironmentId
    $script:TenantId      = Read-RequiredGuid 'TenantId'       $TenantId
    $script:ApplicationId = Read-RequiredGuid 'ApplicationId'  $ApplicationId
    Write-Info "Environment: $script:EnvironmentId"
    Write-Info "App registration: $script:ApplicationId (tenant $script:TenantId)"

    # Asked for here too, so a missing org URL fails before the install rather
    # than after registration has already succeeded.
    if ($EnableComputerUse) {
        $script:OrgUrl = Read-RequiredOrgUrl 'OrgUrl' $OrgUrl
        Write-Info "Dataverse org: $script:OrgUrl"
    }
}

function Get-PadSecret {
    if ($env:PAD_SECRET) {
        Write-Info 'Client secret loaded from PAD_SECRET (will be piped over stdin).'
        return $env:PAD_SECRET
    }
    # Prompt rather than fail: by this point the user has already chosen to
    # register. Masked input, and it never lands in the environment.
    $secure = Read-Host '    Client secret' -AsSecureString
    $plain  = [System.Net.NetworkCredential]::new('', $secure).Password
    if (-not $plain) {
        throw 'No client secret given. Set $env:PAD_SECRET or enter it when asked.'
    }
    Write-Info 'Client secret captured (will be piped over stdin).'
    return $plain
}

# ------------------------------ install ------------------------------

function Get-InstalledPad {
    if (Test-Path $RegExe) {
        return (Get-Item $RegExe).VersionInfo.ProductVersion
    }
    return $null
}

function Install-Pad {
    $existing = Get-InstalledPad
    if ($existing -and -not $Reinstall) {
        Write-Step "Power Automate already installed (version $existing) - skipping install"
        Write-Info "Path: $RegExe"
        Write-Info 'Use -Reinstall to download and install it again.'
        return
    }

    Write-Step 'Downloading Power Automate for desktop installer'
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $installer = Join-Path $WorkDir 'Setup.Microsoft.PowerAutomate.exe'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $installer -UseBasicParsing
    $sizeMb = [math]::Round((Get-Item $installer).Length / 1MB, 1)
    Write-Ok "Downloaded ($sizeMb MB) to $installer"

    Write-Step 'Installing silently'
    Write-Info 'Components: Power Automate for desktop, machine-runtime app, browser extensions.'
    # -ACCEPTEULA is mandatory for unattended installation.
    $proc = Start-Process -FilePath $installer `
        -ArgumentList @('-Silent', '-Install', '-ACCEPTEULA') `
        -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        throw "Installer failed with exit code $($proc.ExitCode)."
    }
    Write-Ok 'Installer completed.'
}

function Confirm-Install {
    Write-Step 'Verifying installation'

    $ver = Get-InstalledPad
    if (-not $ver) {
        throw "Installation verification failed: $RegExe not found."
    }
    Write-Ok "Registration tool present (version $ver)"
    Write-Info "Path: $RegExe"
}

# ------------------------- browser extensions -------------------------

function Enable-BrowserExtension {
    <#
      The installer ships the extension, but a user can still disable it.
      Listing it in the browser's ExtensionInstallForcelist machine policy makes
      the browser install it on next launch, enable it, and grey out the remove
      toggle. Edge is Chromium, so the policy works identically - only the key
      and the extension ID differ.
    #>
    param(
        [string]$Browser,
        [string]$PolicyKey,
        [string]$ExtensionId,
        [string]$UpdateUrl
    )

    Write-Step "Force-installing the Power Automate extension in $Browser"
    if (-not (Test-Path $PolicyKey)) {
        New-Item -Path $PolicyKey -Force | Out-Null
        Write-Info "Created policy key: $PolicyKey"
    }

    # Entries are numbered values; an existing one may carry a ';<update-url>'
    # suffix, so match on the ID prefix rather than the whole string.
    $policy = Get-Item -Path $PolicyKey
    foreach ($name in $policy.GetValueNames()) {
        if ($policy.GetValue($name) -like "$ExtensionId*") {
            Write-Ok "Already in the forcelist (value '$name') - no change."
            return
        }
    }

    $entry = if ($UpdateUrl) { "$ExtensionId;$UpdateUrl" } else { $ExtensionId }
    $index = 1
    while ($policy.GetValueNames() -contains "$index") { $index++ }
    New-ItemProperty -Path $PolicyKey -Name "$index" -Value $entry `
                     -PropertyType String -Force | Out-Null

    Write-Ok "Added $index = $entry"
    Write-Info "$Browser must be restarted to apply."
}

function Enable-BrowserExtensions {
    if ($SkipChromeExtension) {
        Write-Step 'Chrome extension policy skipped'
    } else {
        Enable-BrowserExtension -Browser 'Chrome' `
            -PolicyKey   'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist' `
            -ExtensionId $ChromeExtensionId
        Write-Info 'Verify at chrome://policy/'
    }

    if ($SkipEdgeExtension) {
        Write-Step 'Edge extension policy skipped'
    } else {
        # Edge defaults to its own add-ons store, but state it explicitly so the
        # entry cannot be resolved against the Chrome Web Store by mistake.
        Enable-BrowserExtension -Browser 'Edge' `
            -PolicyKey   'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist' `
            -ExtensionId $EdgeExtensionId `
            -UpdateUrl   'https://edge.microsoft.com/extensionwebstore/api/v1/crx'
        Write-Info 'Verify at edge://policy/'
    }
}

# ----------------------------- register ------------------------------

function Build-Arguments {
    # -clientsecret carries no value: the secret is read from stdin.
    $a = @('-register',
           '-applicationid', $ApplicationId,
           '-clientsecret',
           '-tenantid', $TenantId,
           '-environmentid', $EnvironmentId,
           '-machinename', $MachineName,
           '-machinedescription', $MachineDescription)
    if ($Force) { $a += '-force' }
    return $a
}

function Register-Machine {
    param([string]$Credential)

    $argList = Build-Arguments
    Write-Step "Registering '$MachineName' to environment $EnvironmentId"

    # Log the command with the credential omitted.
    Write-Info ('Command: PAD.MachineRegistration.Silent.exe ' + ($argList -join ' '))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $RegExe
    $psi.Arguments = ($argList | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.WorkingDirectory       = $PadRoot

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.WriteLine($Credential)
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
  - The client secret in PAD_SECRET is wrong or expired.
  - The machine is already registered elsewhere (re-run with -Force to override).
  - Outbound connectivity to the Power Automate cloud services is blocked.
"@
    }
    Write-Ok 'Registration succeeded.'
}

function Confirm-Runtime {
    # The runtime is a Windows service; the PAD GUI never needs to be launched.
    Write-Step 'Verifying machine runtime service'
    $svcs = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'UIFlow|PowerAutomate|PAD' }
    if (-not $svcs) {
        Write-Warning 'No Power Automate service found - the machine may not stay connected.'
        return
    }
    foreach ($s in $svcs) {
        Write-Info ("{0} [{1}] - {2}" -f $s.Name, $s.DisplayName, $s.Status)
        if ($s.Status -ne 'Running' -and $s.StartType -ne 'Disabled') {
            try   { Start-Service $s.Name -ErrorAction Stop; Write-Ok "  started $($s.Name)" }
            catch { Write-Warning "  could not start $($s.Name): $($_.Exception.Message)" }
        }
    }
}

# --------------------------- computer use ----------------------------

function Get-DataverseToken {
    <# Client credentials for the same service principal used to register. #>
    param([string]$Org, [string]$Tenant, [string]$AppId, [string]$Secret)

    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $AppId
        client_secret = $Secret      # POST body, never the URL or command line
        scope         = "$Org/.default"
    }
    $token = Invoke-RestMethod -Method Post -Body $body `
        -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token"
    if (-not $token.access_token) { throw 'Token endpoint returned no access_token.' }
    return $token.access_token
}

function Get-DataverseError {
    <#
      Dataverse explains itself in the response body; the status code alone
      cannot tell "app has no application user here" from "its role lacks the
      privilege". PS 7 exposes the body on ErrorDetails, 5.1 often only in the
      raw stream - so try both.
    #>
    param($ErrorRecord)

    $body = $ErrorRecord.ErrorDetails.Message
    if (-not $body) {
        # PS 5.1: WebException carries a readable stream. PS 7 has no
        # GetResponseStream, so this probe just yields $null and we fall through.
        $stream = $null
        try { $stream = $ErrorRecord.Exception.Response.GetResponseStream() } catch { }
        if ($stream) {
            try {
                $stream.Position = 0
                $body = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
            } catch { }
        }
    }
    if (-not $body) { return $ErrorRecord.Exception.Message }

    try { $parsed = ($body | ConvertFrom-Json).error } catch { return $body }
    if ($parsed.message) { return "$($parsed.message) [code $($parsed.code)]" }
    return $body
}

function Invoke-Dataverse {
    param([string]$Method, [string]$Uri, $Body, [string]$Token)

    $headers = @{
        Authorization    = "Bearer $Token"
        Accept           = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
    }
    if ($Method -eq 'Patch') {
        # Update-only: without If-Match, Dataverse would upsert a new row.
        $headers['If-Match'] = '*'
    }
    # Not $args - that is an automatic variable.
    $call = @{ Method = $Method; Uri = $Uri; Headers = $headers }
    if ($Body) {
        $call['Body']        = ($Body | ConvertTo-Json -Compress)
        $call['ContentType'] = 'application/json'
    }
    try { return Invoke-RestMethod @call }
    catch {
        # Query string dropped: it is noise here, and keeps any filter value out
        # of the message.
        throw "$Method $($Uri -replace '\?.*$', '') failed: $(Get-DataverseError $_)"
    }
}

function Find-FlowMachine {
    <#
      The machine's row in Dataverse. Present = registered to this environment.

      Matched on NAME within the environment, which is the only handle we have -
      a machine of the same name registered from a DIFFERENT box looks identical
      from here. Attempts > 1 covers the lag after a fresh registration.
    #>
    param([string]$Org, [string]$Token, [string]$Machine, [int]$Attempts = 1)

    $filter = "name eq '$($Machine -replace "'", "''")'"
    $query  = "$Org/api/data/v9.2/flowmachines?`$filter=$([uri]::EscapeDataString($filter))" +
              '&$select=name,statuscode,lastheartbeatdate,_flowmachinegroupid_value'

    foreach ($attempt in 1..$Attempts) {
        $row = (Invoke-Dataverse -Method Get -Uri $query -Token $Token).value | Select-Object -First 1
        if ($row) { return $row }
        if ($attempt -lt $Attempts) {
            Write-Info "Machine not visible in Dataverse yet (attempt $attempt) - retrying in 5s"
            Start-Sleep -Seconds 5
        }
    }
    return $null
}

function Enable-ComputerUse {
    <#
      "Enable for computer use" is not a machine setting - it is the usagetype
      column on the machine's GROUP (flowmachinegroups): 1 = computer use,
      0 = default desktop flows.

      usagetype is absent from Microsoft's published schema reference. It works
      today over the supported Dataverse Web API, but treat it as undocumented -
      hence fail-soft everywhere here, with the portal toggle as the fallback.
    #>
    param(
        [string]$Org,
        [string]$Tenant,
        [string]$AppId,
        [string]$Secret,
        [string]$Machine,
        # Straight from the local registration when we have it; otherwise looked
        # up by machine name.
        [string]$GroupId,
        [int]$LookupAttempts = 3
    )

    Write-Step "Enabling '$Machine' for computer use"
    $api = "$Org/api/data/v9.2"
    $token = Get-DataverseToken -Org $Org -Tenant $Tenant -AppId $AppId -Secret $Secret
    Write-Info "Authenticated to $Org"

    if ($GroupId) {
        Write-Info "Machine group from local registration: $GroupId"
    } else {
        # Several attempts: a just-registered machine can take a moment to appear.
        # $machineRow, not $machine - PowerShell variables are case-insensitive,
        # so $machine would clobber the $Machine parameter.
        $machineRow = Find-FlowMachine -Org $Org -Token $token -Machine $Machine -Attempts $LookupAttempts
        if (-not $machineRow) {
            Write-Warning "No machine named '$Machine' found in this environment - cannot enable computer use."
            return $false
        }
        Write-Info ("Machine found (statuscode {0}, last heartbeat {1})" -f
                    $machineRow.statuscode, $machineRow.lastheartbeatdate)

        $GroupId = $machineRow._flowmachinegroupid_value
        if (-not $GroupId) {
            Write-Warning "Machine '$Machine' has no machine group assigned. The computer-use flag lives on the group, so there is nothing to set."
            return $false
        }
    }
    $groupId = $GroupId

    # 2. Read the group. Already enabled means no PATCH at all.
    $group = Invoke-Dataverse -Method Get -Token $token `
        -Uri "$api/flowmachinegroups($groupId)?`$select=name,usagetype"
    Write-Info "Group: $($group.name) [$groupId], usagetype = $($group.usagetype)"

    if ($group.usagetype -eq 1) {
        Write-Ok 'Already enabled for computer use - no change made.'
        return $true
    }

    # 3. Set only usagetype. The portal also sends statecode/statuscode/
    #    preferredqueuingtype/groupmetadata; including those risks overwriting
    #    settings changed elsewhere.
    Invoke-Dataverse -Method Patch -Token $token `
        -Uri "$api/flowmachinegroups($groupId)" -Body @{ usagetype = 1 } | Out-Null

    # 4. Confirm it took, rather than trusting the 204.
    $after = Invoke-Dataverse -Method Get -Token $token `
        -Uri "$api/flowmachinegroups($groupId)?`$select=name,usagetype"
    if ($after.usagetype -ne 1) {
        throw "PATCH accepted but usagetype is still $($after.usagetype)."
    }

    Write-Ok "Enabled for computer use (usagetype = 1)."
    Write-Warning "This applies to EVERY machine in group '$($group.name)', not just $Machine."
    return $true
}

# ------------------------------- main -------------------------------
try {
    Write-Step 'Preflight'
    Assert-Admin
    Test-WindowsEdition
    Test-Connectivity

    # Is this box already registered? Answered from the local registration
    # record, so it costs nothing and happens before we ask anything.
    $local = Get-LocalRegistration
    $alreadyConnected = $false
    if ($local -and -not $Force) {
        Write-Step 'Machine is already registered'
        Write-Info "Org: $($local.OrgUrl)"
        Write-Info "Machine ID: $($local.MachineId)"
        Write-Info "Machine group: $($local.GroupId)"
        Write-Info 'Skipping registration. Re-run with -Force to register again (this breaks existing connections).'
        $alreadyConnected = $true

        # Defaults from the registration itself, so neither has to be passed.
        if (-not $OrgUrl -and $local.OrgUrl)     { $OrgUrl   = $local.OrgUrl }
        if (-not $TenantId -and $local.TenantId) { $TenantId = $local.TenantId }
    }

    # Details and credential are collected BEFORE the download, so a typo or a
    # missing secret fails in seconds rather than after a several-minute install.
    $doRegister = if ($alreadyConnected) { $false } else { Confirm-Registration }
    $cred = $null
    if ($doRegister) {
        Read-RegistrationDetails
        $cred = Get-PadSecret
    }
    elseif ($alreadyConnected -and $EnableComputerUse) {
        # Registration is done, but the Dataverse call still needs an identity.
        Write-Step 'Computer-use details'
        $OrgUrl        = Read-RequiredOrgUrl 'OrgUrl'        $OrgUrl
        $TenantId      = Read-RequiredGuid   'TenantId'      $TenantId
        $ApplicationId = Read-RequiredGuid   'ApplicationId' $ApplicationId
        $cred          = Get-PadSecret
    }

    Install-Pad
    Confirm-Install

    # $null = not attempted, $true/$false = attempted with that outcome.
    $computerUse = $null

    if ($doRegister) {
        Register-Machine -Credential $cred
        Confirm-Runtime
        # The machine group id only exists locally once registration has run.
        $local = Get-LocalRegistration
    }

    if ($EnableComputerUse -and ($doRegister -or $alreadyConnected)) {
        # Undocumented column: never let it fail the run. Registration has
        # already succeeded by this point and the portal toggle still works.
        try {
            $computerUse = Enable-ComputerUse -Org $OrgUrl -Tenant $TenantId `
                -AppId $ApplicationId -Secret $cred -Machine $MachineName `
                -GroupId $local.GroupId
        }
        catch {
            $computerUse = $false
            Write-Warning $_.Exception.Message
        }
        if (-not $computerUse) {
            Write-Host @"
Could not enable computer use automatically.
Enable it manually: Power Automate > Machines > $MachineName > Settings >
Enable for computer use.
"@ -ForegroundColor Yellow
        }
    }

    # Held until here because the computer-use step needs the same secret.
    if ($cred) {
        $cred = $null
        Remove-Item Env:\PAD_SECRET -ErrorAction SilentlyContinue
    }

    Enable-BrowserExtensions

    Write-Step 'Setup complete'
    if ($doRegister -or $alreadyConnected) {
        $computerUseLine = if ($computerUse) {
@"
It is ENABLED FOR COMPUTER USE and ready to use.
    (usagetype = 1 on its machine group - applies to every machine in that group.)
"@
        } elseif ($null -ne $computerUse) {
@"
COMPUTER USE IS NOT ENABLED - the automatic step failed. Do it manually:
    Machines -> $MachineName -> Settings -> Enable for computer use -> Save
"@
        } else {
@"
REMAINING MANUAL STEP:
    Machines -> $MachineName -> Settings -> Enable for computer use -> Save
    (or re-run with -EnableComputerUse)
"@
        }
        $stateLine = if ($alreadyConnected) {
            "Machine '$MachineName' was ALREADY CONNECTED - registration was skipped. It appears at:"
        } else {
            "Machine '$MachineName' is installed and registered, and should now appear at:"
        }
        Write-Host @"
$stateLine
    make.powerautomate.com -> Machines

$computerUseLine
Poll readiness from the backend via the Dataverse flowmachine table:
    GET /api/data/v9.2/flowmachines?`$filter=name eq '$MachineName'
        &`$select=name,statuscode,lastheartbeatdate,agentversion
    Ready when statuscode = 1 (Active) with a recent lastheartbeatdate.

Restart Chrome and Edge to pick up the extension policy.
Verify at chrome://policy/ and edge://policy/

REMINDER: do not clone this VM now that Power Automate is installed and registered.
"@ -ForegroundColor Green
    } else {
        Write-Host @"
Power Automate is installed and the browser extension policies are in place.

The machine was NOT registered, so it will not appear in Power Automate.
Register it later with (it will ask for the environment, tenant and app IDs):

    .\Setup_PAD_Final.ps1 -MachineName '$MachineName' -Register Yes

Restart Chrome and Edge to pick up the extension policy.
Verify at chrome://policy/ and edge://policy/
"@ -ForegroundColor Green
    }
    exit 0
}
catch {
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
