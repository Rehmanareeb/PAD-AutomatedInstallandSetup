<#
.SYNOPSIS
  PART 1 of 2 - Install Power Automate for desktop and the machine-runtime app
  on a fresh Windows machine.

.DESCRIPTION
  Credential-free. This script only puts the software on the box; it does not
  register the machine to any environment. Run Register-PadMachine.ps1 (part 2)
  afterwards to authenticate and bind the machine to a Power Platform environment.

  Steps:
    1. Preflight - administrator rights, Windows edition, outbound connectivity.
    2. Download the Power Automate for desktop installer.
    3. Silent install, including the machine-runtime app and web extension.
    4. Verify the install produced the expected binaries and services.

  IMPORTANT: never clone a VM after this script has run. Microsoft's guidance is
  not to clone a virtual machine after installing the Power Automate machine
  runtime - the registration and machine identity will break. Keep the base
  image clean and run this post-clone on each machine.

.EXAMPLE
  .\Install-PadRuntime.ps1

.EXAMPLE
  .\Install-PadRuntime.ps1 -InstallerUrl 'https://.../Setup.Microsoft.PowerAutomate.exe' -Verbose

.OUTPUTS
  Exit code 0 on success, 1 on failure.
#>

[CmdletBinding()]
param(
    # Verify the current download link from the Power Automate install docs.
    [string]$InstallerUrl = 'https://go.microsoft.com/fwlink/?linkid=2102613',

    [string]$WorkDir = "$env:TEMP\pad-install",

    # Skip the network reachability probe (e.g. when a proxy blocks ICMP/TCP tests
    # but traffic is actually allowed).
    [switch]$SkipConnectivityCheck,

    # Reinstall even if Power Automate is already present.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$PadRoot = "${env:ProgramFiles(x86)}\Power Automate Desktop"
$RegExe  = Join-Path $PadRoot 'PAD.MachineRegistration.Silent.exe'

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Info { param([string]$m) Write-Host "    $m" }

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

function Get-InstalledPad {
    if (Test-Path $RegExe) {
        $ver = (Get-Item $RegExe).VersionInfo.ProductVersion
        return $ver
    }
    return $null
}

function Install-Pad {
    $existing = Get-InstalledPad
    if ($existing -and -not $Force) {
        Write-Step "Power Automate already installed (version $existing) - skipping"
        Write-Info 'Use -Force to reinstall.'
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

    # The machine runtime runs as a Windows service. It does NOT require the
    # Power Automate GUI to be launched.
    $svcs = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'UIFlow|PowerAutomate|PAD' }
    if ($svcs) {
        foreach ($s in $svcs) {
            Write-Info ("Service: {0} [{1}] - {2}" -f $s.Name, $s.DisplayName, $s.Status)
        }
    } else {
        Write-Warning 'No Power Automate services detected. The runtime component may not have installed.'
    }
}

# ------------------------------- main -------------------------------
try {
    Write-Step 'Preflight'
    Assert-Admin
    Test-WindowsEdition
    Test-Connectivity

    Install-Pad
    Confirm-Install

    Write-Step 'Part 1 complete'
    Write-Host @'
Power Automate for desktop and the machine-runtime app are installed.

The machine is NOT yet registered and will not appear in Power Automate.
Run part 2 to authenticate and bind it to an environment:

    .\Register-PadMachine.ps1 -EnvironmentId <env-guid> -Username <service-account-upn>

REMINDER: do not clone this VM now that Power Automate is installed.
'@ -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}