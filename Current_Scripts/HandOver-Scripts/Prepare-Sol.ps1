<#
.SYNOPSIS
  Hand-over step 1: prepare the solution package and import it into the target
  Power Platform environment.

.DESCRIPTION
  Runs flow step 1 (solution preparation) end to end, inside the VM:

      1.1  download the solution package from an https URL
      1.2  create the Azure Key Vault, assign RBAC, store the F&O credentials
           as secrets                                   -> Create-KeyVault.ps1
      1.3  unpack, retarget the SharePoint and Dataverse values, point the
           cre44_FnoUsername / cre44_FnoPassword environment variables at the
           vault secrets, repack                        -> Flow-1.ps1
      1.4  create the Dataverse and SharePoint connections, fill in the
           deployment settings file, and import         -> Set-SolutionConnections.ps1

  This script owns no solution-editing, vault or connection logic of its own. It
  drives the original scripts in Current_Scripts, so a fix in any of them reaches
  this pipeline for free.

  ORDER. The Key Vault is created before the connections, as required. The pack
  step sits between them because Set-SolutionConnections.ps1 reads the connection
  references out of a packed solution, so the retargeted zip has to exist first.
  The import is done by Set-SolutionConnections.ps1 rather than Flow-1.ps1,
  because only it can pass --settings-file - without that, the imported agent
  arrives with empty connection references and its tools fail at run time.

  NOTHING IS SHARED OR PUBLISHED HERE. That is Share-Agents.ps1, after the
  machine and the agent binding exist.

  GATE: the import must succeed before Machine-and-Cua.ps1. On success the
  solutions in the environment are listed so you can see yours landed.

  Answers are cached in handover-state.json next to this script so the later
  steps do not ask again. Secrets are never written there.

  Two originals have their configuration as top-level constants rather than
  parameters. They are NOT modified - they are copied to a temp file with the
  constant lines rewritten from the parameters below, the copy is run, and the
  copy is deleted. If a constant is ever renamed in the original, the rewrite
  fails loudly instead of silently falling back to the demo tenant's values.

  REQUIRES: az login (Key Vault, connections), and a pac auth profile in the
  same tenant (unpack, pack, import).

.PARAMETER SourceRoot
  Folder holding the original scripts. Defaults to this script's parent, i.e.
  Current_Scripts.

.PARAMETER SolutionUrl
  https URL serving the solution zip. Prompted for if neither this nor
  -SolutionPath is given.

.PARAMETER SolutionPath
  Local solution zip, as an alternative to -SolutionUrl.

.PARAMETER OrgUrl
  Target Dataverse org URL, e.g. https://org35fd7a12.crm.dynamics.com

.PARAMETER EnvironmentId
  Power Platform environment GUID. Looked up by Set-SolutionConnections.ps1 from
  -OrgUrl when omitted.

.PARAMETER SharePointUrl
  SharePoint site the solution's flows should point at, e.g.
  https://contoso.sharepoint.com/sites/AICOE

.PARAMETER SubscriptionId
  Azure subscription holding the Key Vault.

.PARAMETER ResourceGroupName
  Resource group for the Key Vault. Created if missing.

.PARAMETER Location
  Azure region for the resource group and vault, e.g. 'East US'.

.PARAMETER KeyVaultName
  Key Vault name. Must be globally unique. Created if missing; an existing vault
  is reused only when it already uses Azure RBAC.

.PARAMETER AllowedEnvironmentTag
  Value for the AllowedEnvironments tag stamped on both secrets. Power Platform
  reads this tag to decide which environments may resolve the secret. Format is
  '<tenantId>,<environmentId>' as Copilot Studio writes it.

.PARAMETER UsernameSecretName
  Key Vault secret name holding the F&O username. Default 'FnoUsername'.

.PARAMETER PasswordSecretName
  Key Vault secret name holding the F&O password. Default 'FnoPassword'.

.PARAMETER FnoUsername
  F&O username to store in the vault. Prompted for if omitted.

.PARAMETER FnoPassword
  F&O password, as a SecureString. Prompted for with -AsSecureString if omitted.
  Never written to disk or to a command line.

.PARAMETER FnoUsernameSecretUri
  Key Vault secret reference the solution's cre44_FnoUsername environment
  variable is pointed at. Built from -SubscriptionId / -ResourceGroupName /
  -KeyVaultName / -UsernameSecretName when omitted, which is almost always what
  you want.

.PARAMETER FnoPasswordSecretUri
  Same for cre44_FnoPassword.

.PARAMETER DataverseAppId
  Client id of the app registration the new Dataverse connection signs in as.
  That app must already be an application user in the target environment.
  Required unless -SkipCreateDataverse.

.PARAMETER DataverseTenantId
  Tenant of that app registration.

.PARAMETER DataverseAppSecret
  Its client secret, as a SecureString. Passed to Set-SolutionConnections.ps1
  through $env:PP_CLIENT_SECRET, so it never lands on a command line or in shell
  history.

.PARAMETER Connection
  Pins a connector to an existing connection id, 'connector=id', comma
  separated. Use it where more than one connection would match and you want the
  run to stay unattended. Passed straight through to Set-SolutionConnections.ps1.

.PARAMETER SkipKeyVault
  Skip step 1.2 entirely. The vault and both secrets must already exist, because
  the environment variables are still pointed at them.

.PARAMETER SkipCreateDataverse
  Bind to an existing Dataverse connection instead of creating one. Requires
  either exactly one Dataverse connection in the environment or a -Connection pin.

.PARAMETER SkipCreateSharePoint
  Bind to an existing SharePoint connection instead of creating one. SharePoint
  connection creation opens a browser for one interactive sign-in - the connector
  offers no service principal option - so pass this on later runs, once a
  reusable connection exists.

.PARAMETER SkipImport
  Stop after writing the deployment settings file. Nothing in the environment is
  touched and the gate check is skipped.

.PARAMETER OutFile
  Where the retargeted package is written. Defaults to
  .\<name>_Changed.zip in the current directory.

.EXAMPLE
  .\Prepare-Sol.ps1 -SolutionUrl https://files.catbox.moe/abc123.zip `
                    -OrgUrl https://org35fd7a12.crm.dynamics.com `
                    -SharePointUrl https://contoso.sharepoint.com/sites/AICOE `
                    -SubscriptionId 0c33fa37-4fa1-466d-a891-46af9e2f6e44 `
                    -ResourceGroupName rg-cua-uat -Location 'East US' `
                    -KeyVaultName kv-cua-uat-01 `
                    -AllowedEnvironmentTag '44b93ad0-...,eaa3f01b-...' `
                    -DataverseAppId <app-guid> -DataverseTenantId <tenant-guid>

  Full run. Prompts only for the F&O credentials and the Dataverse app secret.

.EXAMPLE
  .\Prepare-Sol.ps1 -SolutionPath .\CUAExecutionValidator.zip -SkipKeyVault -SkipImport

  Dry run: retarget and pack against an existing vault, write the settings file,
  touch nothing in the environment.

.EXAMPLE
  .\Prepare-Sol.ps1 -Help
#>
[CmdletBinding()]
param(
    [switch] $Help,

    [ValidateNotNullOrEmpty()]
    [string] $SourceRoot = (Split-Path -Parent $PSScriptRoot),

    # --- solution source -------------------------------------------------------
    [string] $SolutionUrl,
    [string] $SolutionPath,
    [string] $OutFile,

    # --- target ---------------------------------------------------------------
    [string] $OrgUrl,
    [string] $EnvironmentId,
    [string] $SharePointUrl,
    [ValidateSet('literal', 'envvar')]
    [string] $Mode = 'literal',
    [ValidateSet('Unmanaged', 'Managed', 'Both')]
    [string] $PackageType = 'Unmanaged',

    # --- Azure Key Vault ------------------------------------------------------
    [string] $SubscriptionId,
    [string] $ResourceGroupName,
    [string] $Location,
    [string] $KeyVaultName,
    [string] $AllowedEnvironmentTag,
    [ValidateNotNullOrEmpty()]
    [string] $UsernameSecretName = 'FnoUsername',
    [ValidateNotNullOrEmpty()]
    [string] $PasswordSecretName = 'FnoPassword',
    [string] $FnoUsername,
    [securestring] $FnoPassword,

    # Secret REFERENCES the solution's environment variables point at. Built from
    # the vault parameters above when omitted.
    [string] $FnoUsernameSecretUri,
    [string] $FnoPasswordSecretUri,

    # --- connections ----------------------------------------------------------
    [string]   $DataverseAppId,
    [string]   $DataverseTenantId,
    [securestring] $DataverseAppSecret,
    [string]   $DataverseConnectionName = 'dataverse-sp',
    [string]   $SharePointConnectionName = 'sharepoint-oauth',
    [string[]] $Connection = @(),
    [ValidateRange(30, 1800)]
    [int]      $ConsentTimeoutSeconds = 300,
    [string]   $SettingsFile,

    # --- stage control --------------------------------------------------------
    [switch] $SkipKeyVault,
    [switch] $SkipCreateDataverse,
    [switch] $SkipCreateSharePoint,
    [switch] $SkipImport
)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

# 5.1 still negotiates TLS 1.0/1.1 by default on some builds; the download
# endpoints require 1.2.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# ==============================================================================
# helpers
# ==============================================================================
function Write-Stage { param([string] $m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Info  { param([string] $m) Write-Host "    $m" }
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

# Everything downstream unpacks and imports this file, so prove it is really a
# zip. A link that 404s saves the HTML error page under a .zip name.
function Test-ZipSignature {
    param([string] $File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    $fs = [IO.File]::OpenRead($File)
    try {
        $b = [byte[]]::new(4)
        if ($fs.Read($b, 0, 4) -lt 4) { return $false }
        return $b[0] -eq 0x50 -and $b[1] -eq 0x4B -and $b[2] -eq 0x03 -and $b[3] -eq 0x04
    } finally { $fs.Dispose() }
}

# --- running an original that keeps its config in top-level constants ---------
# Create-KeyVault.ps1 has no param() block. Rather than editing it - the
# originals are read-only here - its text is copied with the constant lines
# rewritten, and the copy is run. A rename in the original makes this THROW
# rather than quietly running against the demo subscription.
function Set-ScriptVariable {
    param([string[]] $Lines, [string] $Name, [string] $Expression)
    $pattern = '^\s*\$' + [regex]::Escape($Name) + '\s*='
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch $pattern) { continue }

        # Consume the whole assignment: backtick continuations, and open
        # parentheses that carry it onto the next line. Replacing only the first
        # line would leave orphan argument lines behind and break parsing.
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

# ==============================================================================
# collect every input up front, so nothing prompts mid-run
# ==============================================================================
try {
    Write-Stage 'Step 1 - Solution preparation'

    $keyVault  = Get-Source 'Create-KeyVault.ps1'
    $flow      = Get-Source 'Flow-1.ps1'
    $setConns  = Get-Source 'Set-SolutionConnections.ps1'

    if ($SolutionPath -and -not (Test-Path -LiteralPath $SolutionPath -PathType Leaf)) {
        throw "Not a file: $SolutionPath"
    }
    if (-not $SolutionUrl -and -not $SolutionPath) {
        $SolutionUrl = Read-RequiredValue 'Solution package https URL' (Get-Fallback $SolutionUrl 'SolutionUrl')
    }
    if ($SolutionUrl -and $SolutionUrl -notmatch '^https://') {
        throw "Refusing a non-https solution source: $SolutionUrl"
    }

    $OrgUrl = Read-RequiredValue 'Target Dataverse org URL (https://org....crm.dynamics.com)' (Get-Fallback $OrgUrl 'OrgUrl')
    $OrgUrl = $OrgUrl.Trim().TrimEnd('/')
    if ($OrgUrl -notmatch '^https://') { throw "-OrgUrl must be an https org URL, got: $OrgUrl" }

    if (-not $EnvironmentId) { $EnvironmentId = $State.EnvironmentId }
    if (-not $SharePointUrl) { $SharePointUrl = Get-Fallback $SharePointUrl 'SharePointUrl' }

    if (-not $SkipKeyVault) {
        $SubscriptionId        = Read-RequiredValue 'Azure subscription id'                     (Get-Fallback $SubscriptionId        'SubscriptionId')
        $ResourceGroupName     = Read-RequiredValue 'Resource group name'                       (Get-Fallback $ResourceGroupName     'ResourceGroupName')
        $Location              = Read-RequiredValue 'Azure region (e.g. East US)'               (Get-Fallback $Location              'Location')
        $KeyVaultName          = Read-RequiredValue 'Key Vault name (globally unique)'          (Get-Fallback $KeyVaultName          'KeyVaultName')
        $AllowedEnvironmentTag = Read-RequiredValue 'AllowedEnvironments tag (<tenantId>,<environmentId>)' (Get-Fallback $AllowedEnvironmentTag 'AllowedEnvironmentTag')
        $FnoUsername           = Read-RequiredValue 'F&O username'                              $FnoUsername
        $FnoPassword           = Read-RequiredSecret 'F&O password'                             $FnoPassword
    } else {
        $SubscriptionId    = Get-Fallback $SubscriptionId    'SubscriptionId'
        $ResourceGroupName = Get-Fallback $ResourceGroupName 'ResourceGroupName'
        $KeyVaultName      = Get-Fallback $KeyVaultName      'KeyVaultName'
    }

    # The environment variables must point at the vault whether or not this run
    # created it, so these are required either way.
    if (-not $FnoUsernameSecretUri) {
        $KeyVaultName   = Read-RequiredValue 'Key Vault name'    $KeyVaultName
        $SubscriptionId = Read-RequiredValue 'Azure subscription id' $SubscriptionId
        $ResourceGroupName = Read-RequiredValue 'Resource group name' $ResourceGroupName
        $FnoUsernameSecretUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$KeyVaultName/secrets/$UsernameSecretName"
    }
    if (-not $FnoPasswordSecretUri) {
        $FnoPasswordSecretUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$KeyVaultName/secrets/$PasswordSecretName"
    }

    if (-not $SkipCreateDataverse) {
        $DataverseAppId     = Read-RequiredValue  'Dataverse connection app (client) id' (Get-Fallback $DataverseAppId    'DataverseAppId')
        $DataverseTenantId  = Read-RequiredValue  'Tenant id'                            (Get-Fallback $DataverseTenantId 'TenantId')
        $DataverseAppSecret = Read-RequiredSecret 'Dataverse app client secret'          $DataverseAppSecret
    }

    if (-not $OutFile) { $OutFile = Join-Path (Get-Location).Path 'Solution_Changed.zip' }
    if (-not $SettingsFile) { $SettingsFile = Join-Path $PSScriptRoot 'deploy-settings.json' }

    Write-Info "target      $OrgUrl"
    Write-Info "source      $(if ($SolutionUrl) { $SolutionUrl } else { $SolutionPath })"
    Write-Info "vault       $(if ($SkipKeyVault) { "$KeyVaultName (skipped, must exist)" } else { $KeyVaultName })"
    Write-Info "packed to   $OutFile"

    # ==========================================================================
    # 1.1  fetch
    # ==========================================================================
    Write-Stage '1.1  Download the solution package'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('handover_sol_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        if ($SolutionUrl) {
            $src = Join-Path $work 'solution.zip'
            Write-Info "GET $SolutionUrl"
            Invoke-WebRequest -Uri $SolutionUrl -OutFile $src -MaximumRedirection 5 -UseBasicParsing
        } else {
            $src = (Resolve-Path -LiteralPath $SolutionPath).Path
        }
        if (-not (Test-ZipSignature $src)) {
            throw "Not a zip: $src. A link that 404s saves the HTML error page under a .zip name, which looks exactly like this."
        }
        Write-Info "$src  $([math]::Round((Get-Item -LiteralPath $src).Length / 1KB)) KB"

        # ======================================================================
        # 1.2  Key Vault and secrets
        # ======================================================================
        if ($SkipKeyVault) {
            Write-Stage '1.2  Key Vault (skipped)'
            Write-Info 'The vault and both secrets must already exist - the environment variables still point at them.'
        } else {
            Write-Stage '1.2  Create the Key Vault and store the F&O credentials'
            # The F&O password is handed over in the process environment, never in
            # the temp copy on disk and never on a command line.
            Invoke-SourceScript -Path $keyVault -Overrides @{
                SubscriptionId             = "'$SubscriptionId'"
                ResourceGroupName          = "'$ResourceGroupName'"
                Location                   = "'$Location'"
                KeyVaultName               = "'$KeyVaultName'"
                PowerPlatformEnvironmentId = "'$AllowedEnvironmentTag'"
                UsernameSecretName         = "'$UsernameSecretName'"
                PasswordSecretName         = "'$PasswordSecretName'"
                fnoUsername                = '$env:HANDOVER_FNO_USERNAME'
                fnoPasswordSecure          = 'ConvertTo-SecureString $env:HANDOVER_FNO_PASSWORD -AsPlainText -Force'
            } -EnvVars @{
                HANDOVER_FNO_USERNAME = $FnoUsername
                HANDOVER_FNO_PASSWORD = (ConvertFrom-Secure $FnoPassword)
            }
        }

        # ======================================================================
        # 1.3  retarget, point the environment variables at the vault, repack
        # ======================================================================
        Write-Stage '1.3  Retarget values, point environment variables at the vault, repack'
        $a = @{
            SolutionPath     = $src
            EnvironmentUrl   = $OrgUrl
            OutFile          = $OutFile
            Mode             = $Mode
            PackageType      = $PackageType
            FnoUsernameValue = $FnoUsernameSecretUri
            FnoPasswordValue = $FnoPasswordSecretUri
            SkipImport       = $true    # the import happens in 1.4, with the settings file
            NoShare          = $true    # sharing and publishing are Share-Agents.ps1
        }
        if ($SharePointUrl) { $a.SharePointUrl = $SharePointUrl }
        & $flow @a
        if (-not (Test-Path -LiteralPath $OutFile)) { throw "Packing reported success but $OutFile is not there." }
        Write-Info "packed   $OutFile"

        # ======================================================================
        # 1.4  create the Dataverse and SharePoint connections, bind, import
        # ======================================================================
        Write-Stage '1.4  Create the Dataverse and SharePoint connections, then import'
        $c = @{
            SolutionZip              = $OutFile
            EnvironmentUrl           = $OrgUrl
            SettingsFile             = $SettingsFile
            NewConnectionName        = $DataverseConnectionName
            SharePointConnectionName = $SharePointConnectionName
            ConsentTimeoutSeconds    = $ConsentTimeoutSeconds
        }
        if ($Connection.Count)     { $c.Connection      = $Connection }
        if ($EnvironmentId)        { $c.EnvironmentId   = $EnvironmentId }
        if (-not $SkipImport)      { $c.Import          = $true }
        if (-not $SkipCreateDataverse) {
            $c.CreateDataverse = $true
            $c.AppId           = $DataverseAppId
            $c.TenantId        = $DataverseTenantId
        }
        if (-not $SkipCreateSharePoint) {
            $c.CreateSharePoint = $true
            Write-Info 'SharePoint has no service principal option - a browser will open for one interactive sign-in.'
        }

        # Set-SolutionConnections.ps1 reads the Dataverse app secret from the
        # environment on purpose, so it never reaches a command line or history.
        $hadSecret = $null -ne $env:PP_CLIENT_SECRET
        $priorSecret = $env:PP_CLIENT_SECRET
        try {
            if (-not $SkipCreateDataverse) { $env:PP_CLIENT_SECRET = ConvertFrom-Secure $DataverseAppSecret }
            & $setConns @c
        }
        finally {
            if ($hadSecret) { $env:PP_CLIENT_SECRET = $priorSecret }
            else { Remove-Item Env:\PP_CLIENT_SECRET -ErrorAction SilentlyContinue }
        }
    }
    finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # ==========================================================================
    # gate
    # ==========================================================================
    Write-Stage 'Gate - import succeeded'
    if ($SkipImport) {
        Write-Host '    Import skipped (-SkipImport). Settings file written, environment untouched.' -ForegroundColor Yellow
    } else {
        $pac = (Get-Command pac, pac.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $pac) { $pac = "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\pac.cmd" }
        if (Test-Path $pac) {
            & $pac solution list --environment $OrgUrl 2>&1 | ForEach-Object { Write-Info "$_" }
            Write-Gate 'Confirm your solution is listed above before running Machine-and-Cua.ps1.'
        } else {
            Write-Warning 'pac not found, so the solution list could not be shown. Confirm the import in the maker portal.'
        }
    }

    Save-State @{
        OrgUrl                = $OrgUrl
        EnvironmentId         = $EnvironmentId
        SharePointUrl         = $SharePointUrl
        SolutionUrl           = $SolutionUrl
        SubscriptionId        = $SubscriptionId
        ResourceGroupName     = $ResourceGroupName
        Location              = $Location
        KeyVaultName          = $KeyVaultName
        AllowedEnvironmentTag = $AllowedEnvironmentTag
        DataverseAppId        = $DataverseAppId
        TenantId              = $DataverseTenantId
        SettingsFile          = $SettingsFile
        PackedSolution        = $OutFile
    }

    Write-Stage 'Step 1 complete'
    Write-Info 'Next: .\Machine-and-Cua.ps1   (run as Administrator, on the VM itself)'
}
catch {
    Write-Host "`nSTEP 1 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
