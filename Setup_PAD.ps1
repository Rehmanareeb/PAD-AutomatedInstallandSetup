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
       Optional - see -Register.
    4. Force-install the Power Automate extension in Chrome via machine policy,
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

.EXAMPLE
  # Interactive: choose whether to register, and be asked for the details.
  .\Setup_PAD.ps1

.EXAMPLE
  # Install and Chrome extension only, no prompts, no registration details.
  .\Setup_PAD.ps1 -Register No

.EXAMPLE
  # Unattended registration.
  $env:PAD_SECRET = '<client secret>'
  .\Setup_PAD.ps1 -Register Yes `
      -EnvironmentId '20bbbb76-91c1-efde-bf32-8a5468336104' `
      -ApplicationId '<app client id>' `
      -TenantId      'edda99bb-bab6-4c4c-8aa1-4b99e8e09c1b' `
      -MachineName   'CUA-UAT-01'

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
    #   No  - skip registration, do the install and Chrome extension only
    [ValidateSet('Ask', 'Yes', 'No')]
    [string]$Register = 'Ask',

    # Microsoft Power Automate extension for Chrome (PAD v2.27 or later).
    [string]$ChromeExtensionId = 'ljglajjnnkapghbckkcmodicjhacbfhk',

    # Leave Chrome policy alone (e.g. the extension is already deployed by GPO).
    [switch]$SkipChromeExtension,

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
      Chrome extension step. -Register Yes/No answers this without prompting,
      which is what unattended provisioning should pass.
    #>
    if ($Register -eq 'Yes') { Write-Info 'Registration: yes (-Register Yes).'; return $true }
    if ($Register -eq 'No')  { Write-Info 'Registration: skipped (-Register No).'; return $false }

    Write-Step 'Connect this machine to Power Platform?'
    Write-Info "Machine name: $MachineName"
    if ($EnvironmentId) { Write-Info "Environment : $EnvironmentId" }
    Write-Host ''
    Write-Host '    [1] Yes - register this machine now'
    Write-Host '    [2] No  - skip registration, continue to the Chrome extension'
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

# -------------------------- chrome extension --------------------------

function Enable-ChromeExtension {
    <#
      The installer ships the extension, but the user can still disable it.
      Listing it in the ExtensionInstallForcelist machine policy makes Chrome
      install it on next launch, enable it, and grey out the remove toggle.
    #>
    if ($SkipChromeExtension) {
        Write-Step 'Chrome extension policy skipped'
        return
    }

    Write-Step 'Force-installing the Power Automate Chrome extension'
    $key = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
        Write-Info "Created policy key: $key"
    }

    # Entries are numbered values; an existing one may carry a ';<update-url>'
    # suffix, so match on the ID prefix rather than the whole string.
    $policy = Get-Item -Path $key
    foreach ($name in $policy.GetValueNames()) {
        if ($policy.GetValue($name) -like "$ChromeExtensionId*") {
            Write-Ok "Already in the forcelist (value '$name') - no change."
            return
        }
    }

    $index = 1
    while ($policy.GetValueNames() -contains "$index") { $index++ }
    New-ItemProperty -Path $key -Name "$index" -Value $ChromeExtensionId `
                     -PropertyType String -Force | Out-Null

    Write-Ok "Added $index = $ChromeExtensionId"
    Write-Info 'Chrome must be restarted to apply. Verify at chrome://policy/'
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

# ------------------------------- main -------------------------------
try {
    Write-Step 'Preflight'
    Assert-Admin
    Test-WindowsEdition
    Test-Connectivity

    # Details and credential are collected BEFORE the download, so a typo or a
    # missing secret fails in seconds rather than after a several-minute install.
    $doRegister = Confirm-Registration
    $cred = $null
    if ($doRegister) {
        Read-RegistrationDetails
        $cred = Get-PadSecret
    }

    Install-Pad
    Confirm-Install

    if ($doRegister) {
        Register-Machine -Credential $cred
        $cred = $null
        Remove-Item Env:\PAD_SECRET -ErrorAction SilentlyContinue
        Confirm-Runtime
    }

    Enable-ChromeExtension

    Write-Step 'Setup complete'
    if ($doRegister) {
        Write-Host @"
Machine '$MachineName' is installed and registered, and should now appear at:
    make.powerautomate.com -> Machines

REMAINING MANUAL STEP (no documented API):
    Machines -> $MachineName -> Settings -> Enable for computer use -> Save

Poll readiness from the backend via the Dataverse flowmachine table:
    GET /api/data/v9.2/flowmachines?`$filter=name eq '$MachineName'
        &`$select=name,statuscode,lastheartbeatdate,agentversion
    Ready when statuscode = 1 (Active) with a recent lastheartbeatdate.

Restart Chrome to pick up the extension policy. Verify at chrome://policy/

REMINDER: do not clone this VM now that Power Automate is installed and registered.
"@ -ForegroundColor Green
    } else {
        Write-Host @"
Power Automate is installed and the Chrome extension policy is in place.

The machine was NOT registered, so it will not appear in Power Automate.
Register it later with (it will ask for the environment, tenant and app IDs):

    .\Setup_PAD.ps1 -MachineName '$MachineName' -Register Yes

Restart Chrome to pick up the extension policy. Verify at chrome://policy/
"@ -ForegroundColor Green
    }
    exit 0
}
catch {
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
