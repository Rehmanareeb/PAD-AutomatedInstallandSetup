<#
.SYNOPSIS
  Hand-over step 2: turn this VM into a Power Automate machine, then point
  Agent 2's Computer Use tool at it. Flow steps 3 and 4 in one script.

.DESCRIPTION
  Run this ON THE VM, as Administrator, after Prepare-Sol.ps1 has imported the
  solution.

  Flow step 3 - machine setup and CUA enablement:

      3.1  install Power Automate for desktop and register this machine to the
           target environment                          -> Setup_PAD_Final.ps1
      3.2  enable the machine for computer use         -> Setup_PAD_Final.ps1
      3.3  create the Computer Use connection carrying the machine's Windows
           credential, plus its Dataverse connection reference
                                                       -> CreateCUA-Connection.ps1
      GATE: the machine is registered and the connection exists.

  Flow step 4 - agent configuration:

      4.1  point Agent 2's Computer Use tool at the connection
      4.2  bind the connection reference in the agent's CUA action
      4.3  save and verify the binding                 -> Switch-CUA-Con.ps1
      4.4  configure Agent 2's manual (Custom Entra) authentication
                                                       -> Agent2-ManualAuth-AUtomation.ps1

  The agent is NOT published here by default - that is Share-Agents.ps1, so a
  half-configured agent never reaches the runtime. Pass -PublishNow to publish
  the CUA binding as soon as it verifies.

  AUTHENTICATION, the part that is easy to get wrong. Three operations here need
  three different identities, and no single credential covers all of them:

    * Machine registration takes a username or an app registration. It cannot
      take a token - it provisions a local machine identity, not a row you POST.
    * Creating the Computer Use connection CANNOT be app-only. Authorisation
      comes from the connectivity service and only an identity the connection is
      shared with may do it; these are created with sharing disabled, so a
      service principal fails with code 10006 even holding System Administrator.
      Expect one interactive sign-in.
    * Everything else is an ordinary delegated call off `az login`.

  Two originals keep their configuration in top-level constants rather than a
  param() block. They are NOT modified - each is copied to a temp file with the
  constant lines rewritten from the parameters below, the copy is run, and the
  copy is deleted. If a constant is renamed in an original, the rewrite throws
  rather than silently running against the demo tenant.

  Secrets are held as SecureString and handed to the originals through the
  process environment, never through a temp file on disk and never on a command
  line where the process list would show them.

  REQUIRES: Administrator, az login, and a pac auth profile in the same tenant.

.PARAMETER SourceRoot
  Folder holding the original scripts. Defaults to this script's parent, i.e.
  Current_Scripts.

.PARAMETER OrgUrl
  Target Dataverse org URL, e.g. https://org35fd7a12.crm.dynamics.com

.PARAMETER EnvironmentId
  Power Platform environment GUID that the machine registers into and the
  Computer Use connection is created in.

.PARAMETER TenantId
  Directory (tenant) id.

.PARAMETER ApplicationId
  Client id of the app registration used for silent machine registration. It
  needs Microsoft Flow Service permissions with admin consent and an application
  user in the target environment.

.PARAMETER PadClientSecret
  That app's client secret, as a SecureString. Handed to Setup_PAD_Final.ps1
  through $env:PAD_SECRET, which is how that script already expects it.

.PARAMETER MachineName
  Name this machine registers under, and the name looked up when the Computer
  Use connection is created. Defaults to $env:COMPUTERNAME.

.PARAMETER MachineDescription
  Description stamped on the registration. Default 'CUA'.

.PARAMETER ConnectionName
  Display name for the Computer Use connection. Defaults to '<MachineName>-CUA'.

.PARAMETER MachineUsername
  Windows account that signs in to this machine. The connection carries it.

.PARAMETER MachinePassword
  That account's password, as a SecureString. Prompted for with -AsSecureString
  if omitted.

.PARAMETER Agent2SchemaName
  Schema name of the Computer Use agent, e.g. cr720_Agent2UITesting. Schema name,
  not display name. Prompted for if omitted.

.PARAMETER Agent2CuaComponentSchema
  Schema name of that agent's Computer Use action, e.g.
  cr720_Agent2UITesting.action.Computeruse-Computeruse. The connection reference
  row is named <this>.shared_computeroperator.<connection id>.

.PARAMETER Agent2DisplayName
  Display name of the agent as it appears in Copilot Studio, e.g.
  'Agent 2 UI Testing'. Used by the manual-authentication step, which looks the
  bot up by display name rather than schema name.

.PARAMETER SolutionUniqueName
  Unique name of the solution the agent lives in. Sent as a header by the
  manual-authentication step. Optional.

.PARAMETER AuthClientId
  Client id of the Entra app registration Agent 2 authenticates its users with.
  This is a different app from -ApplicationId.

.PARAMETER AuthClientSecret
  That app's client secret, as a SecureString. Prompted for if omitted.

.PARAMETER AuthTenantId
  Tenant of the authentication app. Defaults to -TenantId.

.PARAMETER Interactive
  Sign in to Dataverse with a device code for the binding step instead of
  reusing `az login`.

.PARAMETER PublishNow
  Publish Agent 2 as soon as the CUA binding verifies, instead of leaving the
  publish to Share-Agents.ps1.

.PARAMETER SkipRegistration
  Skip 3.1 and 3.2. The machine must already be registered and enabled for
  computer use.

.PARAMETER SkipConnection
  Skip 3.3. Requires -ConnectionName naming a connection that already exists.

.PARAMETER SkipBinding
  Skip 4.1 to 4.3.

.PARAMETER SkipManualAuth
  Skip 4.4. Agent 2's authentication is left exactly as the imported solution
  set it.

.PARAMETER Force
  Re-register the machine even if it is already registered. THIS BREAKS EXISTING
  CONNECTIONS to the machine.

.EXAMPLE
  .\Machine-and-Cua.ps1 -OrgUrl https://org35fd7a12.crm.dynamics.com `
                        -EnvironmentId 20bbbb76-91c1-efde-bf32-8a5468336104 `
                        -TenantId edda99bb-bab6-4c4c-8aa1-4b99e8e09c1b `
                        -ApplicationId <pad-app-guid> `
                        -MachineName CUA-UAT-01 `
                        -MachineUsername CONTOSO\svc-cua `
                        -Agent2SchemaName cr720_Agent2UITesting `
                        -Agent2CuaComponentSchema cr720_Agent2UITesting.action.Computeruse-Computeruse `
                        -Agent2DisplayName 'Agent 2 UI Testing' `
                        -AuthClientId <auth-app-guid>

  Full run. Prompts only for the three secrets.

.EXAMPLE
  .\Machine-and-Cua.ps1 -SkipRegistration -ConnectionName CUA-UAT-01-CUA

  The machine is already registered and its connection exists - just rebind
  Agent 2 and set its authentication.

.EXAMPLE
  .\Machine-and-Cua.ps1 -Help
#>
[CmdletBinding()]
param(
    [switch] $Help,

    [ValidateNotNullOrEmpty()]
    [string] $SourceRoot = (Split-Path -Parent $PSScriptRoot),

    # --- environment ----------------------------------------------------------
    [string] $OrgUrl,
    [string] $EnvironmentId,
    [string] $TenantId,

    # --- machine registration -------------------------------------------------
    [string] $ApplicationId,
    [securestring] $PadClientSecret,
    [ValidateNotNullOrEmpty()]
    [string] $MachineName = $env:COMPUTERNAME,
    [ValidateNotNullOrEmpty()]
    [string] $MachineDescription = 'CUA',
    [string] $InstallerUrl,

    # --- computer use connection ---------------------------------------------
    [string] $ConnectionName,
    [string] $MachineUsername,
    [securestring] $MachinePassword,

    # --- agent ----------------------------------------------------------------
    [string] $Agent2SchemaName,
    [string] $Agent2CuaComponentSchema,
    [string] $Agent2DisplayName,
    [string] $SolutionUniqueName,

    # --- agent manual authentication -----------------------------------------
    [string] $AuthClientId,
    [securestring] $AuthClientSecret,
    [string] $AuthTenantId,

    # --- flow control ---------------------------------------------------------
    [switch] $Interactive,
    [switch] $PublishNow,
    [switch] $SkipRegistration,
    [switch] $SkipConnection,
    [switch] $SkipBinding,
    [switch] $SkipManualAuth,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# ==============================================================================
# helpers
# ==============================================================================
function Write-Stage { param([string] $m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Info  { param([string] $m) Write-Host "    $m" }
function Write-Ok    { param([string] $m) Write-Host "    $m" -ForegroundColor Green }
function Write-Gate  { param([string] $m) Write-Host "    GATE  $m" -ForegroundColor Green }

function Read-RequiredValue {
    param([string] $Prompt, [string] $Value)
    while ([string]::IsNullOrWhiteSpace($Value)) { $Value = (Read-Host $Prompt).Trim() }
    $Value
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

function Get-Source {
    param([string] $Name)
    $p = Join-Path $SourceRoot $Name
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "Missing source script: $p`nPass -SourceRoot pointing at the folder holding the Current_Scripts files."
    }
    $p
}

# --- running an original that keeps its config in top-level constants ---------
# CreateCUA-Connection.ps1 and Agent2-ManualAuth-AUtomation.ps1 have no usable
# param() block. Rather than editing them - the originals are read-only here -
# their text is copied with the named assignments rewritten, and the copy is run.
# A rename in an original makes this THROW rather than quietly running against
# the demo tenant's values.
function Set-ScriptVariable {
    param([string[]] $Lines, [string] $Name, [string] $Expression)
    $pattern = '^\s*\$' + [regex]::Escape($Name) + '\s*='
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch $pattern) { continue }

        # Consume the whole assignment: backtick continuations, and open
        # parentheses that carry it onto the next line.
        $end  = $i
        $text = $Lines[$i]
        while ($end -lt $Lines.Count - 1) {
            $opens  = ([regex]::Matches($text, '\(')).Count
            $closes = ([regex]::Matches($text, '\)')).Count
            if (-not (($Lines[$end] -match '`\s*$') -or ($opens -gt $closes))) { break }
            $end++
            $text += "`n" + $Lines[$end]
        }

        $new = @()
        if ($i -gt 0) { $new += $Lines[0..($i - 1)] }
        $new += ('$' + $Name + ' = ' + $Expression)
        if ($end + 1 -lt $Lines.Count) { $new += $Lines[($end + 1)..($Lines.Count - 1)] }
        return , $new
    }
    throw ("Cannot override `$$Name - no top-level assignment to it in the source script. " +
           "It was probably renamed. Fix this script rather than letting the original's " +
           "hard-coded value apply silently.")
}

function Invoke-SourceScript {
    param(
        [string]    $Path,
        [hashtable] $Overrides = @{},
        [hashtable] $EnvVars   = @{}
    )
    $lines = [System.IO.File]::ReadAllLines($Path)
    foreach ($k in $Overrides.Keys) { $lines = Set-ScriptVariable -Lines $lines -Name $k -Expression $Overrides[$k] }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('handover_' + [Guid]::NewGuid().ToString('N') + '_' + [IO.Path]::GetFileName($Path))
    # 5.1 has no 'utf8NoBOM' and its -Encoding utf8 means UTF-8 WITH a BOM, which
    # breaks parsing. Write through .NET so both editions agree.
    [System.IO.File]::WriteAllText($tmp, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    try {
        foreach ($k in $EnvVars.Keys) { Set-Item -Path "Env:$k" -Value $EnvVars[$k] }
        & $tmp
    }
    finally {
        foreach ($k in $EnvVars.Keys) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# --- state carried between the hand-over steps -------------------------------
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
    [System.IO.File]::WriteAllText($StatePath, ($State | ConvertTo-Json -Depth 4),
                                   (New-Object System.Text.UTF8Encoding $false))
    Write-Info "state    $StatePath"
}

# The registration writes the org and tenant here, so later steps need neither.
function Get-LocalRegistration {
    foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Power Automate Desktop\Registration',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Power Automate Desktop\Registration') {
        if (Test-Path $p) { return Get-ItemProperty $p }
    }
}

# ==============================================================================
# collect every input up front, so nothing prompts mid-run
# ==============================================================================
try {
    Write-Stage 'Step 2 - Machine setup and CUA configuration'

    $padSetup  = Get-Source 'Setup_PAD_Final.ps1'
    $createCon = Get-Source 'CreateCUA-Connection.ps1'
    $switchCon = Get-Source 'Switch-CUA-Con.ps1'
    $manualAuth = if ($SkipManualAuth) { $null } else { Get-Source 'Agent2-ManualAuth-AUtomation.ps1' }

    if (-not $SkipRegistration) {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
                   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            throw 'Machine registration needs an elevated session. Re-run this script as Administrator, or pass -SkipRegistration if the machine is already registered.'
        }
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) not found. The connection and binding steps need it - install from https://aka.ms/azure-cli.'
    }

    $OrgUrl = Read-RequiredValue 'Target Dataverse org URL (https://org....crm.dynamics.com)' (Get-Fallback $OrgUrl 'OrgUrl')
    $OrgUrl = $OrgUrl.Trim().TrimEnd('/')
    if ($OrgUrl -notmatch '^https://') { throw "-OrgUrl must be an https org URL, got: $OrgUrl" }

    $EnvironmentId = Read-RequiredValue 'Power Platform environment GUID' (Get-Fallback $EnvironmentId 'EnvironmentId')
    $TenantId      = Read-RequiredValue 'Tenant id'                       (Get-Fallback $TenantId      'TenantId')

    if (-not $SkipRegistration) {
        $ApplicationId   = Read-RequiredValue  'Machine-registration app (client) id' (Get-Fallback $ApplicationId 'ApplicationId')
        $PadClientSecret = Read-RequiredSecret 'Machine-registration app client secret' $PadClientSecret
    }

    if (-not $ConnectionName) { $ConnectionName = Get-Fallback $ConnectionName 'ConnectionName' }
    if (-not $ConnectionName) { $ConnectionName = "$MachineName-CUA" }

    if (-not $SkipConnection) {
        $MachineUsername = Read-RequiredValue  "Windows username that signs in to $MachineName" (Get-Fallback $MachineUsername 'MachineUsername')
        $MachinePassword = Read-RequiredSecret 'Windows password' $MachinePassword
        $Agent2CuaComponentSchema = Read-RequiredValue 'Agent 2 Computer Use action schema (e.g. cr720_Agent2UITesting.action.Computeruse-Computeruse)' (Get-Fallback $Agent2CuaComponentSchema 'Agent2CuaComponentSchema')
    }

    if (-not $SkipBinding -or $PublishNow) {
        $Agent2SchemaName = Read-RequiredValue 'Agent 2 schema name (e.g. cr720_Agent2UITesting - schema name, NOT display name)' (Get-Fallback $Agent2SchemaName 'Agent2SchemaName')
    }

    if (-not $SkipManualAuth) {
        $Agent2DisplayName = Read-RequiredValue  "Agent 2 display name as shown in Copilot Studio (e.g. 'Agent 2 UI Testing')" (Get-Fallback $Agent2DisplayName 'Agent2DisplayName')
        $AuthClientId      = Read-RequiredValue  'Agent authentication app (client) id' (Get-Fallback $AuthClientId 'AuthClientId')
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
    # 3.1 / 3.2  register the machine and enable it for computer use
    # ==========================================================================
    if ($SkipRegistration) {
        Write-Stage '3.1  Machine registration (skipped)'
    } else {
        Write-Stage '3.1  Install Power Automate, register the machine, enable computer use'
        $p = @{
            Register          = 'Yes'
            EnableComputerUse = $true
            EnvironmentId     = $EnvironmentId
            ApplicationId     = $ApplicationId
            TenantId          = $TenantId
            OrgUrl            = $OrgUrl
            MachineName       = $MachineName
            MachineDescription = $MachineDescription
        }
        if ($InstallerUrl) { $p.InstallerUrl = $InstallerUrl }
        if ($Force)        { $p.Force        = $true }

        # Setup_PAD_Final.ps1 reads the secret from PAD_SECRET and pipes it over
        # stdin, so it never appears in the process list.
        $priorPad = $env:PAD_SECRET
        try {
            $env:PAD_SECRET = ConvertFrom-Secure $PadClientSecret
            $global:LASTEXITCODE = 0
            & $padSetup @p
            # That script catches its own errors and exits 1 rather than throwing.
            if ($LASTEXITCODE -ne 0) { throw "Setup_PAD_Final.ps1 failed with exit code $LASTEXITCODE." }
        }
        finally {
            if ($priorPad) { $env:PAD_SECRET = $priorPad } else { Remove-Item Env:\PAD_SECRET -ErrorAction SilentlyContinue }
        }
    }

    # --- gate: is this machine actually registered? ---------------------------
    Write-Stage 'Gate - machine registered'
    $reg = Get-LocalRegistration
    if (-not $reg -or -not $reg.MachineId) {
        throw ('No local Power Automate registration found, so there is no machine for the Computer Use ' +
               'connection to bind to. Re-run without -SkipRegistration, or register from the portal.')
    }
    Write-Ok "machine id    $($reg.MachineId)"
    Write-Ok "machine group $($reg.GroupId)"
    Write-Gate "Confirm '$MachineName' shows Online under Power Automate -> Monitor -> Machines."

    # ==========================================================================
    # 3.3  create the Computer Use connection
    # ==========================================================================
    if ($SkipConnection) {
        Write-Stage '3.3  Computer Use connection (skipped)'
        Write-Info "Binding will use the existing connection '$ConnectionName'."
    } else {
        Write-Stage '3.3  Create the Computer Use connection'
        # The Windows password travels in the process environment. It is never
        # written into the temp copy on disk.
        Invoke-SourceScript -Path $createCon -Overrides @{
            EnvironmentId            = "'$EnvironmentId'"
            DataverseUrl             = "'$OrgUrl'"
            BotComponentSchema       = "'$Agent2CuaComponentSchema'"
            TargetMachineName        = "'$MachineName'"
            NewConnectionDisplayName = "'$ConnectionName'"
            MachineUsername          = '$env:HANDOVER_WIN_USERNAME'
            MachinePassword          = '$env:HANDOVER_WIN_PASSWORD'
        } -EnvVars @{
            HANDOVER_WIN_USERNAME = $MachineUsername
            HANDOVER_WIN_PASSWORD = (ConvertFrom-Secure $MachinePassword)
        }
    }

    # ==========================================================================
    # 4.1 - 4.3  bind the connection into Agent 2's Computer Use action
    # ==========================================================================
    if ($SkipBinding) {
        Write-Stage '4.1  Agent binding (skipped)'
    } else {
        Write-Stage '4.1  Point Agent 2 at the connection, bind and verify'
        $s = @{
            ConnectionName = $ConnectionName
            Bot            = $Agent2SchemaName
            OrgUrl         = $OrgUrl
            TenantId       = $TenantId
        }
        if ($Interactive) { $s.Interactive = $true } else { $s.UseAzureCli = $true }
        # Switch-CUA-Con.ps1 publishes by default. Publishing belongs to
        # Share-Agents.ps1, so it is suppressed unless asked for.
        if (-not $PublishNow) { $s.NoPublish = $true }
        & $switchCon @s
    }

    # ==========================================================================
    # 4.4  manual (Custom Entra) authentication on Agent 2
    # ==========================================================================
    if ($SkipManualAuth) {
        Write-Stage '4.4  Manual authentication (skipped)'
        Write-Info 'Agent 2 keeps whatever authentication the imported solution set.'
    } else {
        Write-Stage '4.4  Configure Agent 2 manual authentication'
        $ov = @{
            TenantId     = "'$AuthTenantId'"
            ClientId     = "'$AuthClientId'"
            ClientSecret = '$env:HANDOVER_AUTH_SECRET'
            DataverseUrl = "'$OrgUrl'"
            BotName      = "'$Agent2DisplayName'"
        }
        # The original sends this as a header only when non-empty.
        $ov.SolutionUniqueName = "'$SolutionUniqueName'"
        Invoke-SourceScript -Path $manualAuth -Overrides $ov -EnvVars @{
            HANDOVER_AUTH_SECRET = (ConvertFrom-Secure $AuthClientSecret)
        }
    }

    Save-State @{
        OrgUrl                   = $OrgUrl
        EnvironmentId            = $EnvironmentId
        TenantId                 = $TenantId
        ApplicationId            = $ApplicationId
        MachineName              = $MachineName
        ConnectionName           = $ConnectionName
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
