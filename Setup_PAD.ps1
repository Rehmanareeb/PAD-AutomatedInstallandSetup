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
    3. Register the machine to the environment. This is what makes it appear in
       Power Automate; there is no agentless path and the PAD GUI is never launched.
    4. Verify the machine-runtime service is running.

  Authentication is by Microsoft Entra app registration only:

    PAD.MachineRegistration.Silent.exe -register -applicationid <app-id>
        -clientsecret -tenantid <tenant-id> -environmentid <env-id>
        -machinename <machine-name> -machinedescription CUA

  The app needs Microsoft Flow Service permissions with admin consent, and an
  application user in the target environment. See README.md.

  Note that -clientsecret takes no value on the command line. The secret is
  supplied through the PAD_SECRET environment variable and piped over stdin -
  never placed on the command line, where it would be visible in the process list.

  IMPORTANT: never clone a VM after this script has run. The registration and
  machine identity will break. Keep the base image clean and run this post-clone
  on each machine.

.PARAMETER EnvironmentId
  The Power Platform environment GUID. Found in the Power Automate portal URL.

.PARAMETER ApplicationId
  Application (client) ID of the Entra app registration.

.PARAMETER TenantId
  Directory (tenant) ID.

.EXAMPLE
  $env:PAD_SECRET = '<client secret>'
  .\Setup_PAD.ps1 `
      -EnvironmentId '20bbbb76-91c1-efde-bf32-8a5468336104' `
      -ApplicationId '<app client id>' `
      -TenantId      'edda99bb-bab6-4c4c-8aa1-4b99e8e09c1b' `
      -MachineName   'CUA-UAT-01'

.OUTPUTS
  Exit code 0 on success, 1 on failure.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentId,

    # Entra app registration.
    [Parameter(Mandatory = $true)][string]$ApplicationId,
    [Parameter(Mandatory = $true)][string]$TenantId,

    [string]$MachineName        = $env:COMPUTERNAME,
    [string]$MachineDescription = 'CUA',

    # Verify the current download link from the Power Automate install docs.
    [string]$InstallerUrl = 'https://go.microsoft.com/fwlink/?linkid=2102613',

    [string]$WorkDir = "$env:TEMP\pad-install",

    # Skip the network reachability probe (e.g. when a proxy blocks ICMP/TCP tests
    # but traffic is actually allowed).
    [switch]$SkipConnectivityCheck,

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

function Get-PadSecret {
    if (-not $env:PAD_SECRET) {
        throw 'No credential found. Set $env:PAD_SECRET to the app registration client secret before running.'
    }
    Write-Info "App registration: $ApplicationId (tenant $TenantId)"
    Write-Info 'Client secret loaded from PAD_SECRET (will be piped over stdin).'
    return $env:PAD_SECRET
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
    # Fail on a missing credential BEFORE spending time on the download/install.
    $cred = Get-PadSecret

    Install-Pad
    Confirm-Install

    Register-Machine -Credential $cred
    $cred = $null
    Remove-Item Env:\PAD_SECRET -ErrorAction SilentlyContinue

    Confirm-Runtime

    Write-Step 'Setup complete'
    Write-Host @"
Machine '$MachineName' is installed and registered, and should now appear at:
    make.powerautomate.com -> Machines

REMAINING MANUAL STEP (no documented API):
    Machines -> $MachineName -> Settings -> Enable for computer use -> Save

Poll readiness from the backend via the Dataverse flowmachine table:
    GET /api/data/v9.2/flowmachines?`$filter=name eq '$MachineName'
        &`$select=name,statuscode,lastheartbeatdate,agentversion
    Ready when statuscode = 1 (Active) with a recent lastheartbeatdate.

REMINDER: do not clone this VM now that Power Automate is installed and registered.
"@ -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
