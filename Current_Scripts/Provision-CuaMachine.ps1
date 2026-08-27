<#
.SYNOPSIS
  Provision a Computer Use machine end to end: install Power Automate for
  desktop, register it, enable it for computer use, create its connection, and
  point the agent at it.

.DESCRIPTION
  Five phases, each skipped when it is already done, so a run that fails part
  way can simply be run again:

      1. Install      Power Automate for desktop.
      2. Register     this machine to the environment.
      3. Computer use set usagetype on the machine's group.
      4. Connection   create '<machine>-Connection', bound to this machine.
      5. Bind         point the agent's Computer Use action at it, and publish.

  Runs ON the machine being provisioned, as Administrator. Phases 1 and 2 act on
  this box; 3 to 5 act on the cloud.

  AUTHENTICATION

  Phases 3 to 5 always run as the account signed into the Azure CLI. They cannot
  run app-only: creating and binding a Computer Use connection is authorised by
  the connectivity service, not by Dataverse, and only an identity the connection
  is shared with - in practice its owner - may do it. An app registration fails
  with code 10006 however many Dataverse roles it holds. So `az login` first.

  Phase 2 cannot use a token at all - the registration tool has no parameter for
  one, and registration provisions a local machine identity rather than writing a
  cloud row. It therefore picks its credential at runtime:

      $env:PAD_SECRET set, with -ApplicationId and -TenantId
          silent, app-registration registration. Nothing to answer.

      otherwise
          -username <the az account>, with -AuthFallback devicecode. One
          sign-in prompt per machine.

  IMPORTANT: never clone a VM after this script has run. The registration and
  machine identity will break. Keep the base image clean and run this post-clone
  on each machine.

.PARAMETER Help
  Print this help and exit, without signing in or touching anything.

.EXAMPLE
  # Whole flow, signing in once at the device-code prompt.
  az login
  .\Provision-CuaMachine.ps1 -EnvironmentId <env-guid> -OrgUrl https://org.crm.dynamics.com

.EXAMPLE
  # Same, with registration silent via the app registration.
  az login
  $env:PAD_SECRET = '<client secret>'
  .\Provision-CuaMachine.ps1 -EnvironmentId <env-guid> -OrgUrl https://org.crm.dynamics.com `
      -ApplicationId <app-guid> -TenantId <tenant-guid>

.EXAMPLE
  # Everything is already provisioned - reports each phase as done and exits.
  .\Provision-CuaMachine.ps1 -EnvironmentId <env-guid> -OrgUrl https://org.crm.dynamics.com

.OUTPUTS
  Exit code 0 on success, 1 on failure.
#>
[CmdletBinding()]
param(
    [switch]$Help,

    # Asked for if not supplied. OrgUrl and TenantId default to whatever the
    # local registration already records, once this machine is registered.
    [string]$EnvironmentId,
    [string]$OrgUrl,
    [string]$TenantId,

    # Only used to make phase 2 silent, together with $env:PAD_SECRET. Without
    # both, registration signs in as the az account instead.
    [string]$ApplicationId,

    # How the registration tool signs in when using the az account. devicecode
    # works over a remote session; interactive needs a browser on this machine.
    [ValidateSet('devicecode', 'interactive')]
    [string]$AuthFallback = 'devicecode',

    [string]$MachineName        = $env:COMPUTERNAME,
    [string]$MachineDescription = 'CUA',

    # Defaults to '<machine name>-Connection'.
    [string]$ConnectionName,

    # The agent whose Computer Use action gets repointed, and published.
    [string]$Bot = 'cr720_Agent2UITesting',

    # Write the binding but do not publish. The runtime stays on the old machine
    # until someone publishes from the designer.
    [switch]$NoPublish,

    # Verify the current download link from the Power Automate install docs.
    [string]$InstallerUrl = 'https://go.microsoft.com/fwlink/?linkid=2102613',
    [string]$WorkDir      = "$env:TEMP\pad-install",

    # Skip the network reachability probe (e.g. when a proxy blocks ICMP/TCP
    # tests but traffic is actually allowed).
    [switch]$SkipConnectivityCheck,

    # Microsoft Power Automate extension IDs, PAD v2.27 or later.
    [string]$ChromeExtensionId = 'ljglajjnnkapghbckkcmodicjhacbfhk',
    [string]$EdgeExtensionId   = 'kagpabjoboikccfdghpdlaaopmgpgfdc',
    [switch]$SkipChromeExtension,
    [switch]$SkipEdgeExtension,

    # Reinstall even if Power Automate is already present.
    [switch]$Reinstall,

    # Re-register even if this machine is already registered. This breaks
    # existing connections to the machine.
    [switch]$Force
)

if ($Help) { Get-Help $PSCommandPath -Detailed; return }

$ErrorActionPreference = 'Stop'
$PadRoot          = "${env:ProgramFiles(x86)}\Power Automate Desktop"
$RegExe           = Join-Path $PadRoot 'PAD.MachineRegistration.Silent.exe'
$ConnectorApiName = 'shared_computeroperator'

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

function Get-RegistrationError {
    <# The two credential paths fail for different reasons; name only the ones
       that can actually apply to the path that ran. #>
    param([int]$ExitCode, [string]$UserName)

    $why = if (Test-AppRegistration) {@"
  - No application user exists in the environment for this app registration.
  - The app's Microsoft Flow Service permissions were never admin-consented.
  - The application user lacks the Desktop Flows Machine Owner role.
  - The client secret in PAD_SECRET is wrong or expired.
"@} else {@"
  - $UserName has no access to environment $EnvironmentId.
  - That account lacks the Desktop Flows Machine Owner role.
  - The sign-in was cancelled, or the device code expired before it was entered.
"@}

    return @"
Registration failed (exit code $ExitCode).

Common causes:
$why
  - The machine is already registered elsewhere (re-run with -Force to override).
  - Outbound connectivity to the Power Automate cloud services is blocked.
"@
}

function Test-AppRegistration {
    <# The app-registration path is available only if all three parts are here. #>
    return [bool]($env:PAD_SECRET -and $ApplicationId -and $TenantId)
}

function Build-Arguments {
    param([string]$UserName)

    $a = @('-register',
           '-environmentid', $EnvironmentId,
           '-machinename', $MachineName,
           '-machinedescription', $MachineDescription)

    if (Test-AppRegistration) {
        # -clientsecret carries no value: the secret is read from stdin, never
        # placed on the command line where the process list would expose it.
        $a += @('-applicationid', $ApplicationId, '-clientsecret', '-tenantid', $TenantId)
    } else {
        # No token can be passed here - the tool has no such parameter - so it
        # signs in itself, as the account already signed into the Azure CLI.
        $a += @('-username', $UserName, '-authenticationfallback', $AuthFallback)
    }
    if ($Force) { $a += '-force' }
    return $a
}

function Register-Machine {
    param([string]$UserName)

    $argList = Build-Arguments -UserName $UserName
    Write-Info ('Command: PAD.MachineRegistration.Silent.exe ' + ($argList -join ' '))

    if (-not (Test-AppRegistration)) {
        # Output is NOT captured on this path: the tool prints a device code and
        # waits for it to be completed. Buffering stdout would hide the code and
        # hang the run waiting on a process that is waiting on the user.
        Write-Info "Complete the $AuthFallback sign-in as $UserName when the tool asks."
        & $RegExe @argList
        if ($LASTEXITCODE -ne 0) { throw (Get-RegistrationError $LASTEXITCODE $UserName) }
        Write-Ok 'Registration succeeded.'
        return
    }

    $Credential = Get-PadSecret
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

    if ($proc.ExitCode -ne 0) { throw (Get-RegistrationError $proc.ExitCode $UserName) }
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

function Find-FlowMachine {
    <#
      The machine's row in Dataverse. Present = registered to this environment.

      Matched on NAME within the environment, which is the only handle we have -
      a machine of the same name registered from a DIFFERENT box looks identical
      from here. Attempts > 1 covers the lag after a fresh registration.
    #>
    param([string]$Machine, [int]$Attempts = 1)

    $filter = "name eq '$($Machine -replace "'", "''")'"
    $query  = "flowmachines?`$filter=$([uri]::EscapeDataString($filter))" +
              '&$select=name,statuscode,lastheartbeatdate,_flowmachinegroupid_value'

    foreach ($attempt in 1..$Attempts) {
        $row = (Invoke-Dv -Path $query).value | Select-Object -First 1
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
        [string]$Machine,
        # Straight from the local registration when we have it; otherwise looked
        # up by machine name.
        [string]$GroupId,
        [int]$LookupAttempts = 3
    )

    Write-Info "Enabling '$Machine' for computer use"

    if ($GroupId) {
        Write-Info "Machine group from local registration: $GroupId"
    } else {
        # Several attempts: a just-registered machine can take a moment to appear.
        # $machineRow, not $machine - PowerShell variables are case-insensitive,
        # so $machine would clobber the $Machine parameter.
        $machineRow = Find-FlowMachine -Machine $Machine -Attempts $LookupAttempts
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
    $group = Invoke-Dv -Path "flowmachinegroups($groupId)?`$select=name,usagetype"
    Write-Info "Group: $($group.name) [$groupId], usagetype = $($group.usagetype)"

    if ($group.usagetype -eq 1) {
        Write-Ok 'Already enabled for computer use - no change made.'
        return $true
    }

    # 3. Set only usagetype. The portal also sends statecode/statuscode/
    #    preferredqueuingtype/groupmetadata; including those risks overwriting
    #    settings changed elsewhere.
    Invoke-Dv -Method Patch -Path "flowmachinegroups($groupId)" -Body @{ usagetype = 1 } | Out-Null

    # 4. Confirm it took, rather than trusting the 204.
    $after = Invoke-Dv -Path "flowmachinegroups($groupId)?`$select=name,usagetype"
    if ($after.usagetype -ne 1) {
        throw "PATCH accepted but usagetype is still $($after.usagetype)."
    }

    Write-Ok "Enabled for computer use (usagetype = 1)."
    Write-Warning "This applies to EVERY machine in group '$($group.name)', not just $Machine."
    return $true
}


# --------------------------- dataverse core --------------------------

function Invoke-Dv {
    <#
      Single Dataverse helper for every phase. Relative path, because every call
      goes to the same org, and -Solution because a connection reference created
      outside the agent's solution is not in the package it publishes.
    #>
    param([string]$Method = 'Get', [string]$Path, $Body, [string]$Solution)

    $call = @{ Method = $Method; Uri = "$OrgUrl/api/data/v9.2/$Path"; Headers = $headers }
    if ($Body) {
        # If-Match keeps a PATCH update-only; without it Dataverse would upsert.
        if ($Method -eq 'Patch') { $call.Headers = $call.Headers + @{ 'If-Match' = '*' } }
        if ($Solution)           { $call.Headers = $call.Headers + @{ 'MSCRM.SolutionUniqueName' = $Solution } }
        $call.ContentType = 'application/json'
        $call.Body        = ($Body | ConvertTo-Json -Compress)
    }
    try { return Invoke-RestMethod @call }
    catch { throw "$Method $($Path -replace '\?.*$', '') failed: $(Get-DataverseError $_)" }
}

# ------------------------------- azure -------------------------------

function Get-AzUser {
    <#
      The identity phases 3 to 5 run as. Also the -username handed to the
      registration tool when there is no app registration to use.
    #>
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) not found. Install it from https://aka.ms/installazurecli, then run: az login'
    }
    # az is a native exe: a failed `account show` sets $LASTEXITCODE, never throws.
    $upn = az account show --query 'user.name' -o tsv 2>$null
    if (-not $upn) {
        Write-Info 'No Azure CLI session - launching az login.'
        az login | Out-Null
        $upn = az account show --query 'user.name' -o tsv 2>$null
    }
    if (-not $upn) { throw "Could not read the signed-in account. Run 'az login' and try again." }
    return $upn
}

function Get-AzToken {
    <# --query/-o tsv so the token never lands in a file or the process list. #>
    param([string]$Resource)

    $t = az account get-access-token --resource $Resource --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $t) {
        throw "az could not get a token for $Resource. Run 'az login' as the account that owns the Computer Use connections.`n$t"
    }
    return $t
}

# ---------------------------- connection -----------------------------

function Get-CuaConnection {
    <#
      An existing connection for this machine. Matched on display name AND the
      machine group it targets, so a stale row of the same name pointing at a
      different machine is never reused.
    #>
    param([string]$Token, [string]$DisplayName, [string]$GroupId)

    $uri = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis/" +
        "$ConnectorApiName/connections?api-version=2016-11-01" +
        "&%24filter=$([uri]::EscapeDataString("environment eq '$EnvironmentId'"))"
    $all = (Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $Token" }).value
    return $all |
        Where-Object { $_.properties.displayName -eq $DisplayName -and
                       $_.properties.connectionParametersSet.values.targetId.value -eq $GroupId } |
        Select-Object -First 1
}

function New-CuaConnection {
    <#
      Creates the Computer Use connection that carries the machine and its
      Windows credential, and returns its id. Reuses one that already matches, so
      a re-run does not leave orphans behind.
    #>
    param([string]$GroupId, [string]$DisplayName)

    $token = Get-AzToken -Resource 'https://service.powerapps.com/'

    $existing = Get-CuaConnection -Token $token -DisplayName $DisplayName -GroupId $GroupId
    if ($existing) {
        Write-Ok "Connection '$DisplayName' already exists ($($existing.name)) - reusing."
        return $existing.name
    }

    Write-Host "`n    Windows account used to sign into $MachineName.`n"
    $user = (Read-Host '    Windows username').Trim()
    if (-not $user) { throw 'Windows username cannot be empty.' }
    $pass = [Net.NetworkCredential]::new('', (Read-Host '    Windows password' -AsSecureString)).Password
    if (-not $pass) { throw 'Windows password cannot be empty.' }

    $id = (New-Guid).Guid.Replace('-', '')

    # The braces on ${id} are load-bearing: '?' is a legal character in a
    # PowerShell variable name, so "$id?api-version" reads as the variable
    # $id?api - empty - and the API rejects it with InvalidApiVersion.
    $uri = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis/" +
        "$ConnectorApiName/connections/${id}?api-version=2016-11-01" +
        "&%24filter=$([uri]::EscapeDataString("environment eq '$EnvironmentId'"))"

    $body = @{
        properties = @{
            displayName = $DisplayName
            environment = @{
                id   = "/providers/Microsoft.PowerApps/environments/$EnvironmentId"
                name = $EnvironmentId
            }
            connectionParametersSet = @{
                name   = 'azureRelay'
                values = @{
                    targetId       = @{ value = $GroupId }
                    username       = @{ value = $user }
                    password       = @{ value = $pass }
                    environment    = @{ value = $EnvironmentId }
                    xrmInstanceUri = @{ value = "$OrgUrl/" }
                    connectionType = @{ value = 'azureRelay' }
                }
            }
        }
    } | ConvertTo-Json -Depth 20

    Write-Info "Creating '$DisplayName' bound to machine group $GroupId (credentials redacted)."
    try {
        Invoke-RestMethod -Method Put -Uri $uri -ContentType 'application/json' -Body $body `
            -Headers @{ Authorization = "Bearer $token" } | Out-Null
    }
    catch {
        $b = $_.ErrorDetails.Message
        if ($b) { $b = $b -replace '(?i)"password"\s*:\s*"[^"]+"', '"password":"<REDACTED>"' }
        throw "Creating the connection failed: $(if ($b) { $b } else { $_.Exception.Message })"
    }

    # Read back rather than trusting the PUT response: targetId is the whole
    # point of the connection, and the PUT body is not documented to echo the
    # parameter set.
    $made = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $token" }
    $got  = $made.properties.connectionParametersSet.values.targetId.value
    if ($got -ne $GroupId) {
        throw "Connection was created, but targetId is '$got', expected '$GroupId'."
    }
    Write-Ok "Created $id (status $($made.properties.statuses.status | Select-Object -First 1))"
    return $id
}

# -------------------------------- main -------------------------------

Write-Step "Provisioning '$MachineName'"

Assert-Admin
Test-WindowsEdition
Test-Connectivity

# Phases 3-5 are delegated-only, so settle the identity before any work: a
# missing az session should fail in seconds, not after a five-minute install.
$upn = Get-AzUser
Write-Info "Azure CLI account: $upn"

$local = Get-LocalRegistration
if ($local -and -not $OrgUrl)   { $OrgUrl   = $local.OrgUrl }
if ($local -and -not $TenantId) { $TenantId = $local.TenantId }

$EnvironmentId = Read-RequiredGuid   'EnvironmentId' $EnvironmentId
$OrgUrl        = Read-RequiredOrgUrl 'OrgUrl'        $OrgUrl
if (-not $ConnectionName) { $ConnectionName = "$MachineName-Connection" }

Write-Step 'Phase 1 of 5 - Power Automate for desktop'
Install-Pad
Confirm-Install

Write-Step 'Phase 2 of 5 - machine registration'
if ($local -and -not $Force) {
    Write-Ok "Already registered as machine $($local.MachineId) - skipping."
} else {
    Register-Machine -UserName $upn
    Confirm-Runtime
    $local = Get-LocalRegistration
    if (-not $local) { throw 'Registration reported success but this machine is not registered locally.' }
}
Write-Info "Machine group: $($local.GroupId)"

# Everything below is Dataverse or Power Apps, as the az account.
$headers = @{ Authorization = "Bearer $(Get-AzToken -Resource $OrgUrl)"; Accept = 'application/json' }

Write-Step 'Phase 3 of 5 - enable for computer use'
# Undocumented column: never let it fail the run, the portal toggle still works.
$cuOk = $false
try   { $cuOk = Enable-ComputerUse -Machine $MachineName -GroupId $local.GroupId }
catch { Write-Warning $_.Exception.Message }
if (-not $cuOk) {
    Write-Warning "Enable it by hand: Power Automate > Machines > $MachineName > Settings > Enable for computer use."
}

Write-Step 'Phase 4 of 5 - Computer Use connection'
$SetConnectionId = New-CuaConnection -GroupId $local.GroupId -DisplayName $ConnectionName

Write-Step 'Phase 5 of 5 - bind the agent and publish'
$rows = @((Invoke-Dv -Path ('connectionreferences?$select=connectionreferenceid,connectionreferencelogicalname,' +
    'connectionreferencedisplayname,connectorid,connectionid&$filter=' +
    [uri]::EscapeDataString("contains(connectorid,'computeroperator')"))).value)

$f = [uri]::EscapeDataString("contains(schemaname,'Computeruse')")
$comp = @((Invoke-Dv -Path "botcomponents?`$select=botcomponentid,schemaname,data&`$filter=$f").value)
if ($comp.Count -ne 1) { throw "Expected one Computer Use bot component, found $($comp.Count)." }
$comp = $comp[0]

$linePattern = '(?m)^(\s*connectionReference:\s*)(\S+?)(?=[ \t\r]*$)'
$m = [regex]::Match($comp.data, $linePattern)
if (-not $m.Success) { throw 'Could not find the connectionReference line in the bot component.' }
$actionName = $m.Groups[2].Value
if ($actionName -notmatch '\.shared_computeroperator\.') {
    throw "The action names '$actionName', which is not a Computer Use connection reference."
}

$prefix     = ($actionName -split '\.shared_computeroperator\.')[0]
$targetName = "$prefix.shared_computeroperator.$SetConnectionId"
$targetRow  = @($rows | Where-Object { $_.connectionreferencelogicalname -eq $targetName })[0]

if ($actionName -eq $targetName -and $targetRow) {
    Write-Host "Already on $SetConnectionId - nothing to do." -ForegroundColor Green
    return
}

# The connection reference has to live in the same solution as the action, or it
# is not in the package the agent publishes. Read it off the action rather than
# hardcoding a name, so this survives being renamed or reused on another agent.
$solutionName = @(@((Invoke-Dv -Path ("solutioncomponents?`$select=_solutionid_value&`$filter=" +
    [uri]::EscapeDataString("objectid eq $($comp.botcomponentid)"))).value) | ForEach-Object {
        (Invoke-Dv -Path "solutions($($_._solutionid_value))?`$select=uniquename").uniquename
    } | Where-Object { $_ -notin 'Default', 'Active' })[0]
if (-not $solutionName) {
    throw 'The Computer Use action is not in any solution but Default, so there is nowhere to put the connection reference. Bind a machine once in the designer instead.'
}

$mine = @($rows | Where-Object { $_.connectionreferencelogicalname -like "$prefix.shared_computeroperator.*" })

Write-Host @"

About to switch the Computer Use machine:
    reference row  $(if ($targetRow) { "reuse $($targetRow.connectionreferenceid)" } else { "create '$targetName'" })
    action         $actionName
                -> $targetName

Existing reference rows are left alone - they are what future switches select
between. $($mine.Count) exist now.

This changes which machine the live agent runs on$(if (-not $NoPublish) { ", and publishes $Bot
afterwards so it takes effect immediately" }).
"@ -ForegroundColor Yellow
if ((Read-Host 'Type YES to proceed') -ne 'YES') { Write-Host 'Cancelled.'; return }

$linkNav = 'botcomponent_connectionreference'

Write-Step 'Connection reference'
if ($targetRow) {
    Write-Info "Row '$targetName' already exists"
} else {
    Invoke-Dv -Method Post -Path 'connectionreferences' -Solution $solutionName `
        -Body @{
            connectionreferencelogicalname = $targetName
            connectionreferencedisplayname = $targetName
            connectorid                    = '/providers/Microsoft.PowerApps/apis/shared_computeroperator'
            connectionid                   = $SetConnectionId
            iscustomizable                 = @{ Value = $false }
        } | Out-Null
    $targetRow = @((Invoke-Dv -Path ("connectionreferences?`$select=connectionreferenceid&`$filter=" +
        [uri]::EscapeDataString("connectionreferencelogicalname eq '$targetName'"))).value)[0]
    if (-not $targetRow) { throw "Created '$targetName' but it cannot be read back." }
    Write-Ok "Created '$targetName' in solution $solutionName"
}

Write-Step 'Action link'
$linked = @((Invoke-Dv -Path "botcomponents($($comp.botcomponentid))?`$select=botcomponentid&`$expand=$linkNav(`$select=connectionreferenceid)").$linkNav)

foreach ($l in $linked | Where-Object { $_.connectionreferenceid -ne $targetRow.connectionreferenceid }) {
    Invoke-Dv -Method Delete -Path "botcomponents($($comp.botcomponentid))/$linkNav($($l.connectionreferenceid))/`$ref" | Out-Null
    Write-Info "unlinked $($l.connectionreferenceid)"
}
if ($targetRow.connectionreferenceid -in $linked.connectionreferenceid) {
    Write-Info 'Already linked'
} else {
    Invoke-Dv -Method Post -Path "botcomponents($($comp.botcomponentid))/$linkNav/`$ref" `
        -Body @{ '@odata.id' = "$OrgUrl/api/data/v9.2/connectionreferences($($targetRow.connectionreferenceid))" } | Out-Null
    Write-Ok "Linked action to $($targetRow.connectionreferenceid)"
}

Write-Step 'Computer Use action'
if ($actionName -eq $targetName) {
    Write-Info 'Action already names this row'
} else {
    $newData = [regex]::Replace($comp.data, $linePattern, { param($x) $x.Groups[1].Value + $targetName })
    Invoke-Dv -Method Patch -Path "botcomponents($($comp.botcomponentid))" -Body @{ data = $newData } | Out-Null
    Write-Ok 'Repointed'
}

Write-Step 'Verifying'
$nowName = [regex]::Match((Invoke-Dv -Path "botcomponents($($comp.botcomponentid))?`$select=data").data, $linePattern).Groups[2].Value
$nowRow  = @((Invoke-Dv -Path ("connectionreferences?`$select=connectionreferenceid,connectionreferencelogicalname,connectionid&`$filter=" +
    [uri]::EscapeDataString("connectionreferencelogicalname eq '$nowName'"))).value)[0]

if ($nowName -ne $targetName) { Write-Warning "The action reads back as '$nowName'."; return }
if (-not $nowRow)             { Write-Warning "No row answers to '$nowName'. Re-run to repair."; return }
if ($nowRow.connectionid -ne $SetConnectionId) {
    Write-Warning "The row reads back with connectionid '$($nowRow.connectionid)'."
    return
}

$inSolution = @(@((Invoke-Dv -Path ("solutioncomponents?`$select=_solutionid_value&`$filter=" +
    [uri]::EscapeDataString("objectid eq $($nowRow.connectionreferenceid)"))).value) | ForEach-Object {
        (Invoke-Dv -Path "solutions($($_._solutionid_value))?`$select=uniquename").uniquename
    })
if ($solutionName -notin $inSolution) {
    Write-Warning "The connection reference is not in solution '$solutionName' (only: $($inSolution -join ', ')). The published agent will not contain it."
    return
}

# The link is the binding, so verify it rather than trusting the POST.
$nowLinked = @((Invoke-Dv -Path "botcomponents($($comp.botcomponentid))?`$select=botcomponentid&`$expand=$linkNav(`$select=connectionreferenceid)").$linkNav)
if ($nowLinked.Count -ne 1 -or $nowLinked[0].connectionreferenceid -ne $nowRow.connectionreferenceid) {
    Write-Warning ("The action is linked to $($nowLinked.Count) reference(s): $($nowLinked.connectionreferenceid -join ', ') - expected only $($nowRow.connectionreferenceid).")
    return
}

Write-Ok "link     -> $($nowRow.connectionreferenceid)"
Write-Ok "action   -> ...$SetConnectionId"
Write-Ok "row      -> connectionid $($nowRow.connectionid)"
Write-Ok "solution -> $solutionName"

if ($NoPublish) {
    Write-Host @"

NOT PUBLISHED, because -NoPublish was passed. The runtime stays on the old
machine until you publish, either from the designer or with:

    pac copilot publish --environment $OrgUrl --bot $Bot
"@ -ForegroundColor Yellow
    return
}

# Only reached once the link, action, connectionid and solution all verified -
# publishing a half-written binding succeeds and then fails every conversation.
Write-Step "Publishing $Bot"
if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    throw "Power Platform CLI (pac) not found - install from https://aka.ms/PowerAppsCLI, or publish from the designer. The binding is already written."
}
$out = pac copilot publish --environment $OrgUrl --bot $Bot 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ("Publish failed. The binding is written, so publish from the designer or re-run with -Publish:`n" +
           ($out -join "`n"))
}
Write-Ok 'Published.'
