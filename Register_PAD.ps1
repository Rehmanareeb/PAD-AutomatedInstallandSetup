<#
.SYNOPSIS
  PART 2 of 2 - Authenticate with a service account and register the machine to
  a Power Platform environment, so it appears in Power Automate.

.DESCRIPTION
  Run after Install-PadRuntime.ps1. This is the only script that handles
  credentials.

  Registration is what makes a machine appear in Power Automate: the machine
  runtime authenticates outbound and creates the flowmachine record. There is no
  agentless path, and the Power Automate GUI never needs to be launched.

  Two authentication modes:

    ServiceAccount   - a dedicated Microsoft Entra user account (UPN).
                       Microsoft supports `-username [UPN]` in place of service
                       principal arguments. The account MUST be excluded from
                       MFA, or unattended registration will fail.

    ServicePrincipal - an Entra app registration. Fully unattended and the more
                       robust option, but requires an application user in the
                       target environment.

  Either way the credential is supplied through the PAD_SECRET environment
  variable and piped over stdin - never placed on the command line, where it
  would be visible in the process list. This matches Microsoft's documented
  "secure input" pattern.

.PARAMETER EnvironmentId
  The Power Platform environment GUID. Found in the Power Automate portal URL.

.EXAMPLE
  # Service account (Entra user)
  $env:PAD_SECRET = '<password>'
  .\Register-PadMachine.ps1 `
      -EnvironmentId '20bbbb76-91c1-efde-bf32-8a5468336104' `
      -Username      'svc-cua@contoso.com' `
      -MachineName   'CUA-UAT-01'

.EXAMPLE
  # Service principal
  $env:PAD_SECRET = '<client secret>'
  .\Register-PadMachine.ps1 -AuthMode ServicePrincipal `
      -EnvironmentId  '20bbbb76-91c1-efde-bf32-8a5468336104' `
      -TenantId       'edda99bb-bab6-4c4c-8aa1-4b99e8e09c1b' `
      -ApplicationId  '<app client id>' `
      -MachineName    'CUA-UAT-01'

.OUTPUTS
  Exit code 0 on success, 1 on failure.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentId,

    [ValidateSet('ServiceAccount', 'ServicePrincipal')]
    [string]$AuthMode = 'ServiceAccount',

    # ServiceAccount mode
    [string]$Username,

    # ServicePrincipal mode
    [string]$TenantId,
    [string]$ApplicationId,
    [string]$CertificateThumbprint,   # alternative to a client secret

    [string]$MachineName        = $env:COMPUTERNAME,
    [string]$MachineDescription = 'CUA execution machine (automated provisioning)',

    # Override an existing registration. This breaks existing connections to the machine.
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
        throw 'This script must run as Administrator.'
    }
}

function Assert-PadInstalled {
    if (-not (Test-Path $RegExe)) {
        throw "Power Automate is not installed ($RegExe not found). Run Install-PadRuntime.ps1 first."
    }
    Write-Info "Registration tool: $RegExe"
}

function Assert-Parameters {
    switch ($AuthMode) {
        'ServiceAccount' {
            if (-not $Username) { throw 'ServiceAccount mode requires -Username (the service account UPN).' }
            Write-Info "Auth mode: ServiceAccount ($Username)"
        }
        'ServicePrincipal' {
            if (-not $TenantId)      { throw 'ServicePrincipal mode requires -TenantId.' }
            if (-not $ApplicationId) { throw 'ServicePrincipal mode requires -ApplicationId.' }
            Write-Info "Auth mode: ServicePrincipal ($ApplicationId)"
        }
    }
}

function Get-Credential {
    # Certificate auth needs no secret.
    if ($AuthMode -eq 'ServicePrincipal' -and $CertificateThumbprint) {
        Write-Info 'Using certificate thumbprint - no secret required.'
        return $null
    }
    if (-not $env:PAD_SECRET) {
        throw 'No credential found. Set $env:PAD_SECRET to the service account password (or client secret) before running.'
    }
    Write-Info 'Credential loaded from PAD_SECRET (will be piped over stdin).'
    return $env:PAD_SECRET
}

function Build-Arguments {
    $a = @('-register')

    if ($AuthMode -eq 'ServiceAccount') {
        # Documented alternative to service principal arguments.
        $a += @('-username', $Username)
    } else {
        $a += @('-applicationid', $ApplicationId, '-tenantid', $TenantId)
        if ($CertificateThumbprint) {
            $a += @('-certificatethumbprint', $CertificateThumbprint)
        } else {
            $a += '-clientsecret'      # no value: supplied on stdin
        }
    }

    $a += @('-environmentid', $EnvironmentId,
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
    if ($Credential) { $proc.StandardInput.WriteLine($Credential) }
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
  - ServiceAccount mode: the account has MFA enforced (unattended sign-in cannot complete).
  - ServicePrincipal mode: no application user exists in the environment for this app.
  - The identity lacks the Environment Maker or Desktop Flows Machine Owner role.
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
    Assert-PadInstalled
    Assert-Parameters
    $cred = Get-Credential

    Register-Machine -Credential $cred
    $cred = $null
    Remove-Item Env:\PAD_SECRET -ErrorAction SilentlyContinue

    Confirm-Runtime

    Write-Step 'Part 2 complete'
    Write-Host @"
Machine '$MachineName' is registered and should now appear at:
    make.powerautomate.com -> Machines

REMAINING MANUAL STEP (no documented API):
    Machines -> $MachineName -> Settings -> Enable for computer use -> Save

Poll readiness from the backend via the Dataverse flowmachine table:
    GET /api/data/v9.2/flowmachines?`$filter=name eq '$MachineName'
        &`$select=name,statuscode,lastheartbeatdate,agentversion
    Ready when statuscode = 1 (Active) with a recent lastheartbeatdate.
"@ -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}