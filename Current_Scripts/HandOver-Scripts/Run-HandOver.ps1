
[CmdletBinding()]
param(
    [switch] $Help,

    # --- stage selection ------------------------------------------------------
    [switch] $SkipPrepare,
    [switch] $SkipMachine,
    [switch] $SkipShare,
    [switch] $OnlyPrepare,
    [switch] $OnlyMachine,
    [switch] $OnlyShare,
    [switch] $WhatIfStages,
    [switch] $SelfTest,

    # --- shared ---------------------------------------------------------------
    [string] $OrgUrl,
    [string] $EnvironmentId,
    [string] $TenantId,

    # ==========================================================================
    # the agents. These ship with the solution and are the same in every
    # environment, so they are defaults rather than prompts.
    # ==========================================================================
    [ValidateNotNullOrEmpty()]
    [string] $Agent1SchemaName         = 'cr720_Agent1TestScript',
    [ValidateNotNullOrEmpty()]
    [string] $Agent2SchemaName         = 'cr720_Agent2UITesting',
    [ValidateNotNullOrEmpty()]
    [string] $Agent2CuaComponentSchema = 'cr720_Agent2UITesting.action.Computeruse-Computeruse',
    [ValidateNotNullOrEmpty()]
    [string] $Agent2DisplayName        = 'Agent 2 UI Testing',
    # Publish order: Agent 1 first, then Agent 2.
    [string[]] $Agent,

    # --- stage 1: solution ----------------------------------------------------
    [string] $SolutionUrl,
    [string] $SolutionPath,
    [string] $OutFile,
    [string] $KeepSource,
    [string] $SharePointUrl,
    [ValidateSet('literal', 'envvar')]
    [string] $Mode = 'literal',
    [ValidateSet('Unmanaged', 'Managed', 'Both')]
    [string] $PackageType = 'Unmanaged',
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
    [string] $FnoUsernameSecretUri,
    [string] $FnoPasswordSecretUri,
    [switch] $SkipFno,

    # Solution-internal names: properties of the package, not of an environment.
    [ValidateNotNullOrEmpty()]
    [string] $SharePointSiteVariable    = 'cre44_SharePointSiteUrl',
    [ValidateNotNullOrEmpty()]
    [string] $DataverseOrgVariable      = 'cre44_DataverseOrgUrl',
    [ValidateNotNullOrEmpty()]
    [string] $SharePointLibraryVariable = 'cre44_SharePointLibraryId',
    [ValidateNotNullOrEmpty()]
    [string] $CsvFlowPattern            = 'Save-Generated-CSV-To-SharePoint-*.json',
    [ValidateNotNullOrEmpty()]
    [string] $SharePointToolPattern     = '*Agent1TestScript.action.SharePoint-Createfile',
    [ValidateNotNullOrEmpty()]
    [string] $DataverseToolPattern      = '*Agent1TestScript.action.MicrosoftDataverse-Addanewrowtoselectedenvironment',

    [switch] $ResolveLibraryId,
    [string] $Library,
    [string] $GraphClientId,
    [securestring] $GraphClientSecret,

    [string]   $DataverseAppId,
    [string]   $DataverseTenantId,
    [securestring] $DataverseAppSecret,
    [ValidateNotNullOrEmpty()]
    [string]   $DataverseConnectionName  = 'dataverse-sp',
    [ValidateNotNullOrEmpty()]
    [string]   $SharePointConnectionName = 'sharepoint-oauth',
    [string[]] $Connection = @(),
    [ValidateRange(30, 1800)]
    [int]      $ConsentTimeoutSeconds = 300,
    [string]   $SettingsFile,
    [switch] $SkipKeyVault,
    [switch] $SkipCreateDataverse,
    [switch] $SkipCreateSharePoint,
    [switch] $SkipImport,

    # --- stage 2: machine and CUA ---------------------------------------------
    [string] $ApplicationId,
    [securestring] $PadClientSecret,
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
    [string] $ConnectionName,
    [string] $MachineUsername,
    [securestring] $MachinePassword,

    # --- stage 2: agent manual (Custom Entra) authentication ------------------
    [string] $AuthClientId,
    [securestring] $AuthClientSecret,
    [string] $AuthTenantId,
    [string] $SolutionUniqueName,
    # Platform constants: the same in every tenant.
    [ValidateNotNullOrEmpty()]
    [string] $ServiceProviderId = '5232e24f-b6c6-4920-b09d-d93a520c92e9',
    [ValidateNotNullOrEmpty()]
    [string] $AuthRedirectUrl   = 'https://token.botframework.com/.auth/web/redirect',
    [ValidateNotNullOrEmpty()]
    [string] $AuthResourceUri   = 'https://graph.microsoft.com',
    [ValidateNotNullOrEmpty()]
    [string] $BapApiBaseUrl     = 'https://api.bap.microsoft.com',

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
    [switch] $Force,

    # --- stage 3: share and publish -------------------------------------------
    [switch] $Everyone,
    [string] $UserEmail,
    [string] $RevokeUserEmail,
    [switch] $RevokeEveryone,
    [switch] $ReportOnly,
    [switch] $NoPublish,
    [switch] $ContinueOnError
)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

# Windows PowerShell 5.1 still negotiates TLS 1.0/1.1 by default on some builds;
# every endpoint below requires 1.2.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# ==============================================================================
# constants
# ==============================================================================
$PadRoot        = "${env:ProgramFiles(x86)}\Power Automate Desktop"
$RegExe         = Join-Path $PadRoot 'PAD.MachineRegistration.Silent.exe'
$ConnectorApi   = 'shared_computeroperator'
$PowerAppsScope = 'https://service.powerapps.com/'
# Microsoft's own public client, which every tenant already trusts for Dataverse -
# no app registration and no "allow public client flows" needed for a device code.
$PublicClientId = '51f81489-12ee-4a9e-aaae-a2591f45987d'

$PolicyName = @{
    0 = 'Any (everyone in org)'
    1 = 'Copilot readers (shared principals only)'
    2 = 'Group membership'
    3 = 'Any (multi-tenant)'
}

# Dataverse rejects a secret-type value that does not match this. Anchored, so
# trailing junk fails here rather than at import time with the useless message
# "This variable didn't save properly."
$SecretRefPattern = '(?i)^/subscriptions/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/resourcegroups/(.+?)/providers/Microsoft\.KeyVault/(.+?)/secrets/(.+)$'
$SecretRefHint    = 'Valid format: /subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>/secrets/<secret>'

# ==============================================================================
# output
# ==============================================================================
function Write-Banner {
    param([string] $m)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $m" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}
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

function Read-RequiredGuid {
    param([string] $Prompt, [string] $Value)
    $v = Read-RequiredValue $Prompt $Value
    if (-not ($v -as [guid])) { throw "Not a valid GUID: '$v'" }
    $v
}

function ConvertFrom-Secure {
    param([securestring] $Secure)
    if ($null -eq $Secure) { return $null }
    [Net.NetworkCredential]::new('', $Secure).Password
}

# ==============================================================================
# shared plumbing
# ==============================================================================

# Windows PowerShell 5.1 has no 'utf8NoBOM' encoding name, and its -Encoding utf8
# means UTF-8 WITH a BOM, which makes pac and the import choke. Write through
# .NET, which behaves the same on 5.1 and 7.
function Set-Utf8NoBom {
    param([string] $LiteralPath, [string] $Value)
    [System.IO.File]::WriteAllText($LiteralPath, $Value + [Environment]::NewLine,
                                   (New-Object System.Text.UTF8Encoding $false))
}

function Resolve-Pac {
    foreach ($n in 'pac', 'pac.cmd', 'pac.exe') {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    foreach ($c in @(
        "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\pac.cmd"
        "$env:USERPROFILE\.dotnet\tools\pac.exe"
        "${env:ProgramFiles}\Microsoft Power Platform CLI\pac.exe"
    )) { if (Test-Path -LiteralPath $c) { return $c } }
    throw 'pac (Power Platform CLI) not found. Install it with: winget install Microsoft.PowerPlatformCLI'
}

# Everything downstream unpacks and imports this file, so prove it really is a
# zip. PK\x03\x04 is the local file header of every zip; a link that 404s saves
# the HTML error page under a .zip name.
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

function Invoke-Az {
    <# az is a native exe: it sets $LASTEXITCODE and never throws. #>
    param([string[]] $Arguments, [string] $ErrorMessage, [switch] $AllowFailure)
    $out = & az @Arguments 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw ("$ErrorMessage`n" + ($out -join "`n"))
    }
    if ($LASTEXITCODE -ne 0) { return $null }
    ($out -join "`n").Trim()
}

function Get-AzSessionKind {
    <#
      What az is signed in as: 'user', 'servicePrincipal', or '' for no session.
      `az account show --query user.type` is the only question both can answer -
      `az ad signed-in-user show` throws for a service principal, which is the
      case this exists to detect.
    #>
    $kind = ''
    try { $kind = (& az account show --query user.type --output tsv --only-show-errors 2>$null | Out-String).Trim() }
    catch { $kind = '' }
    if ($LASTEXITCODE -ne 0) { $kind = '' }
    $kind
}

function Get-AzCallerIdentity {
    <#
      The object id AND principal type of whoever az is signed in as. Both are
      needed: `az role assignment create` wants --assignee-principal-type, and
      the object id comes from a different call for each kind. Signed in with
      --service-principal, `az ad signed-in-user show` fails with "not signed in
      with a user account" - that one line is what used to stop the whole Key
      Vault step running app-only.
    #>
    $kind = Get-AzSessionKind
    if (-not $kind) { throw 'No Azure CLI session. Run: az login' }

    if ($kind -eq 'servicePrincipal') {
        $appId = Invoke-Az @('account', 'show', '--query', 'user.name', '--output', 'tsv') `
            'Could not read the signed-in application id.'
        $oid = Invoke-Az @('ad', 'sp', 'show', '--id', $appId, '--query', 'id', '--output', 'tsv') `
            "Could not read the service principal for app $appId. An app-only session needs the Microsoft Graph APPLICATION permission Application.Read.All, granted with admin consent."
        return @{ Id = $oid; Type = 'ServicePrincipal'; What = "app $appId" }
    }

    $oid = Invoke-Az @('ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv') `
        'Could not read the signed-in Azure user. Run: az login'
    @{ Id = $oid; Type = 'User'; What = 'you' }
}

function Assert-AzUserSession {
    <#
      Most of this script runs perfectly well signed in as a service principal.
      Three things do not, and each fails deep and unhelpfully when one tries:
        - the SharePoint connection - shared_sharepointonline publishes no
          service principal parameter set, so there is nothing to authenticate
        - the Computer Use connection - the connectivity service answers code
          10006, because these connections are created with sharing disabled
        - step 4.4 - the Copilot gateway rejects a token whose idtyp is 'app'
      So say so here, before the call, instead of after it.
    #>
    param([Parameter(Mandatory)][string] $What)
    $kind = Get-AzSessionKind
    if (-not $kind) { throw 'No Azure CLI session. Run: az login' }
    if ($kind -eq 'servicePrincipal') {
        throw ("$What cannot be done by a service principal, and az is signed in as one. " +
               'Sign in as a person for this step (az login), or skip it and reuse an existing ' +
               "object. See 'Where app-only does not work' in README.md.")
    }
}

function New-SecretReference {
    param([string] $Subscription, [string] $ResourceGroup, [string] $Vault, [string] $Secret)
    "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$Vault/secrets/$Secret"
}

function Resolve-AllowedEnvironments {
    <#
      The AllowedEnvironments tag on each secret is a comma-separated list of
      POWER PLATFORM ENVIRONMENT IDs - the environments allowed to resolve that
      secret. It is NOT the tenant id.

      Putting the tenant id here is the failure this guard exists for: the vault
      is created, the tag is set, everything reports success, and then the
      environment variable fails to resolve at run time because no environment in
      the list matches the one asking. Nothing in the Azure or Power Platform
      error text points at the tag.
    #>
    param([string] $Tag, [string] $EnvironmentId, [string] $TenantId)

    if (-not $Tag) { $Tag = $EnvironmentId }
    if (-not $Tag) {
        throw 'No environment id for the AllowedEnvironments tag. Pass -EnvironmentId, or -AllowedEnvironmentTag with the environment id.'
    }

    $ids = @($Tag -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($id in $ids) {
        if (-not ($id -as [guid])) {
            throw "AllowedEnvironments entry '$id' is not a GUID. The tag is a comma-separated list of Power Platform environment ids."
        }
        if ($TenantId -and $id -eq $TenantId) {
            throw @"
The AllowedEnvironments tag contains the TENANT id ($TenantId).

That tag lists the Power Platform ENVIRONMENTS allowed to resolve the secret, not
the tenant. Tagged this way the vault looks correctly configured and then the
environment variable fails to resolve at run time, because no environment in the
list matches the one asking.

Pass -EnvironmentId instead, or -AllowedEnvironmentTag with the environment id
(comma-separated if more than one environment should read the secret).
"@
        }
    }
    $ids -join ','
}

function ConvertFrom-PacConnectionList {
    <# `pac connection list` prints a fixed-width table; names contain spaces. #>
    param([string[]] $Lines)
    $out = @()
    foreach ($line in $Lines) {
        $t = ($line -split '\s+') | Where-Object { $_ }
        if ($t.Count -lt 4) { continue }
        if ($t[-2] -notmatch '^/providers/Microsoft\.PowerApps/apis/') { continue }   # skips the header
        $out += [pscustomobject]@{
            Id        = $t[0]
            Connector = $t[-2] -replace '^.*/', ''
            Status    = $t[-1]
            Name      = ($t[1..($t.Count - 3)] -join ' ')
        }
    }
    $out
}

# --- access-policy rules, pure ------------------------------------------------
# Can a user SHARE take effect under the current policy? Only the "nobody" state -
# group membership with no groups - is corrected.
function Get-SharePolicyFix {
    param([int] $Policy, [string] $Groups)
    if ($Policy -eq 2 -and [string]::IsNullOrWhiteSpace($Groups)) { return @{ Set = 1; Warn = $null } }
    if ($Policy -eq 2) {
        return @{ Set = $null; Warn = "Policy is Group membership ($Groups). A user share is IGNORED - add the user to one of those Entra groups, or re-run with -Everyone." }
    }
    @{ Set = $null; Warn = $null }
}

# Can a user REVOKE take effect? Any / Any-multi-tenant lets everyone chat
# regardless of shares, so narrow it.
function Get-RevokePolicyFix {
    param([int] $Policy, [string] $Groups)
    if ($Policy -eq 0 -or $Policy -eq 3) {
        return @{ Set = 1; Warn = 'Policy was Any, so the revoke alone would change nothing. Narrowing to Copilot readers CUTS OFF every other user who is not individually shared.' }
    }
    if ($Policy -eq 2 -and -not [string]::IsNullOrWhiteSpace($Groups)) {
        return @{ Set = $null; Warn = "Policy is Group membership ($Groups). The row share is not the gate - remove the user from those Entra groups as well." }
    }
    @{ Set = $null; Warn = $null }
}

# ==============================================================================
# self-test - everything that needs no tenant
# ==============================================================================
if ($SelfTest) {
    $rows = ConvertFrom-PacConnectionList @(
        'Id                        Name             API Id                                                       Status',
        'shared-sharepointonl-25   Demouser1@x.com  /providers/Microsoft.PowerApps/apis/shared_sharepointonline  Connected',
        '69f5e3e5258143            T14-GEN1 CUA     /providers/Microsoft.PowerApps/apis/shared_computeroperator  Connected',
        'Connected as somebody@example.com'
    )
    if ($rows.Count -ne 2)                                { throw "selftest: expected 2 rows, got $($rows.Count)" }
    if ($rows[0].Connector -ne 'shared_sharepointonline') { throw "selftest: connector was '$($rows[0].Connector)'" }
    if ($rows[1].Name      -ne 'T14-GEN1 CUA')            { throw "selftest: a name with a space was cut to '$($rows[1].Name)'" }
    if ($rows[0].Id        -ne 'shared-sharepointonl-25') { throw "selftest: id was '$($rows[0].Id)'" }

    $ref = New-SecretReference -Subscription '0c33fa37-4fa1-466d-a891-46af9e2f6e44' -ResourceGroup 'rg' -Vault 'kv' -Secret 'FnoUsername'
    if ($ref -notmatch $SecretRefPattern) { throw "selftest: a built reference must be valid, got $ref" }
    foreach ($bad in 'not-a-ref',
                     '/subscriptions/nope/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv/secrets/s',
                     "$ref`ntrailing") {
        if ($bad -match $SecretRefPattern) { throw "selftest: secret pattern wrongly accepted '$bad'" }
    }

    $c = Get-SharePolicyFix -Policy 2 -Groups ''
    if ($c.Set -ne 1 -or $c.Warn) { throw 'selftest: share, empty group list should move policy to 1' }
    $c = Get-SharePolicyFix -Policy 2 -Groups 'aaaa-bbbb'
    if ($null -ne $c.Set -or -not $c.Warn) { throw 'selftest: share, populated groups should warn, not change policy' }
    foreach ($p in 0, 1, 3) {
        $c = Get-SharePolicyFix -Policy $p -Groups ''
        if ($null -ne $c.Set -or $c.Warn) { throw "selftest: share, policy $p should be left alone" }
    }
    foreach ($p in 0, 3) {
        $c = Get-RevokePolicyFix -Policy $p -Groups ''
        if ($c.Set -ne 1 -or -not $c.Warn) { throw "selftest: revoke, policy $p should narrow to 1 and warn" }
    }
    $c = Get-RevokePolicyFix -Policy 1 -Groups ''
    if ($null -ne $c.Set -or $c.Warn) { throw 'selftest: revoke, policy 1 is already the gate' }
    $c = Get-RevokePolicyFix -Policy 2 -Groups 'aaaa-bbbb'
    if ($null -ne $c.Set -or -not $c.Warn) { throw 'selftest: revoke, group membership should warn about the groups' }
    $c = Get-RevokePolicyFix -Policy 2 -Groups ''
    if ($null -ne $c.Set -or $c.Warn) { throw 'selftest: revoke, policy 2 with no groups already blocks everyone' }

    # The registry shapes that used to crash the machine stage.
    foreach ($case in @(
        @{ In = 'a1-b2,second'; Want = 'a1-b2' }, @{ In = '  a1-b2  '; Want = 'a1-b2' }
        @{ In = ''; Want = '' }, @{ In = $null; Want = '' }, @{ In = ',,'; Want = '' }, @{ In = ' '; Want = '' }
    )) {
        $groups = @("$($case.In)" -split ',' | Where-Object { $_ })
        $got = if ($groups.Count) { "$($groups[0])".Trim() } else { '' }
        if ($got -ne $case.Want) { throw "selftest: GroupIds '$($case.In)' gave '$got', expected '$($case.Want)'" }
        if ($got -isnot [string]) { throw 'selftest: GroupIds must always yield a string' }
    }

    'ok'; return
}

# ==============================================================================
# state carried between runs. Never holds a secret.
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
    [System.IO.File]::WriteAllText($StatePath, ($State | ConvertTo-Json -Depth 4),
                                   (New-Object System.Text.UTF8Encoding $false))
    Write-Info "state    $StatePath"
}

# ============================================================================
# stage 1 - solution preparation
# ============================================================================

function New-FnoKeyVault {
    <#
      Creates the resource group and vault if missing, gives the current user and
      the two service principals that must read the secrets their RBAC roles, and
      stores the F&O credentials tagged for this environment.

      An existing vault is reused ONLY when it already uses Azure RBAC - the
      permission model is never switched automatically, because doing so can
      silently revoke every existing access policy.
    #>
    param(
        [string] $Subscription, [string] $ResourceGroup, [string] $Region, [string] $Vault,
        [string] $AllowedEnvironments, [string] $UsernameSecret, [string] $PasswordSecret,
        [string] $Username, [string] $Password
    )

    Invoke-Az @('account', 'set', '--subscription', $Subscription) 'Could not select the Azure subscription.' | Out-Null
    Write-Info "subscription $Subscription"

    Invoke-Az @('provider', 'register', '--namespace', 'Microsoft.PowerPlatform', '--wait', '--only-show-errors') `
        'Could not register the Microsoft.PowerPlatform resource provider.' | Out-Null
    Write-Info 'Microsoft.PowerPlatform provider registered.'

    if ((Invoke-Az @('group', 'exists', '--name', $ResourceGroup) 'Could not check the resource group.') -eq 'false') {
        Invoke-Az @('group', 'create', '--name', $ResourceGroup, '--location', $Region, '--output', 'none') `
            'Could not create the resource group.' | Out-Null
        Write-Ok "resource group $ResourceGroup created"
    } else {
        Write-Info "resource group $ResourceGroup already exists"
    }

    $vaultId = Invoke-Az @('keyvault', 'list', '--resource-group', $ResourceGroup, '--resource-type', 'vault',
                           '--query', "[?name=='$Vault'].id | [0]", '--output', 'tsv') 'Could not list key vaults.'

    if ([string]::IsNullOrWhiteSpace($vaultId)) {
        Invoke-Az @('keyvault', 'create', '--name', $Vault, '--resource-group', $ResourceGroup,
                    '--location', $Region, '--enable-rbac-authorization', 'true',
                    '--enable-purge-protection', 'true', '--output', 'none') 'Could not create the Key Vault.' | Out-Null
        $vaultId = Invoke-Az @('keyvault', 'show', '--name', $Vault, '--resource-group', $ResourceGroup,
                               '--query', 'id', '--output', 'tsv') 'Could not read back the new Key Vault.'
        Write-Ok "key vault $Vault created"
    } else {
        Write-Info "key vault $Vault already exists"
        $rbac = Invoke-Az @('keyvault', 'show', '--name', $Vault, '--resource-group', $ResourceGroup,
                            '--query', 'properties.enableRbacAuthorization', '--output', 'tsv') 'Could not read the Key Vault.'
        if ($rbac -ne 'true') {
            throw "The existing Key Vault '$Vault' does not use Azure RBAC. Switching its permission model automatically could revoke existing access policies, so it is left alone - migrate it by hand or use a different vault name."
        }
    }
    Write-Info "vault id $vaultId"

    # --- role assignments -----------------------------------------------------
    # Works signed in as a person or as a service principal - see
    # Get-AzCallerIdentity for why that needs two different calls.
    $caller = Get-AzCallerIdentity
    Write-Info "caller $($caller.What) [$($caller.Type)]"

    $assignments = @(
        @{ Id = $caller.Id; Type = $caller.Type; Role = 'Key Vault Secrets Officer'; What = "$($caller.What) (to write the secrets)" }
        @{ Id = $caller.Id; Type = $caller.Type; Role = 'Key Vault Secrets User';    What = "$($caller.What) (to read them back)" }
    )

    # Copilot Studio and Dataverse both resolve the secret at run time, so both
    # need to read it. The Copilot service principal has been renamed once, hence
    # the fallback.
    $copilotSp = Invoke-Az @('ad', 'sp', 'list', '--filter', "displayName eq 'Microsoft Copilot Studio Service'",
                             '--query', '[0].id', '--output', 'tsv') 'Could not query service principals.' -AllowFailure
    if ([string]::IsNullOrWhiteSpace($copilotSp)) {
        Write-Info 'trying the legacy Power Virtual Agents Service name...'
        $copilotSp = Invoke-Az @('ad', 'sp', 'list', '--filter', "displayName eq 'Power Virtual Agents Service'",
                                 '--query', '[0].id', '--output', 'tsv') 'Could not query service principals.' -AllowFailure
    }
    if ([string]::IsNullOrWhiteSpace($copilotSp)) {
        throw 'Neither "Microsoft Copilot Studio Service" nor "Power Virtual Agents Service" was found in this tenant.'
    }
    $assignments += @{ Id = $copilotSp; Type = 'ServicePrincipal'; Role = 'Key Vault Secrets User'; What = 'Copilot Studio' }

    # Microsoft's first-party Dataverse app id - the same in every tenant.
    $dataverseSp = Invoke-Az @('ad', 'sp', 'list', '--filter', "appId eq '00000007-0000-0000-c000-000000000000'",
                               '--query', '[0].id', '--output', 'tsv') 'Could not query the Dataverse service principal.'
    if ([string]::IsNullOrWhiteSpace($dataverseSp)) { throw 'The Dataverse service principal could not be found.' }
    $assignments += @{ Id = $dataverseSp; Type = 'ServicePrincipal'; Role = 'Key Vault Secrets User'; What = 'Dataverse' }

    foreach ($a in $assignments) {
        $existing = Invoke-Az @('role', 'assignment', 'list', '--assignee-object-id', $a.Id,
                                '--scope', $vaultId, '--role', $a.Role,
                                '--query', '[0].id', '--output', 'tsv') 'Could not list role assignments.' -AllowFailure
        if (-not [string]::IsNullOrWhiteSpace($existing)) {
            Write-Info "$($a.Role) already held by $($a.What)"
            continue
        }
        Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $a.Id,
                    '--assignee-principal-type', $a.Type, '--role', $a.Role,
                    '--scope', $vaultId, '--output', 'none') "Could not assign $($a.Role) to $($a.What)." | Out-Null
        Write-Ok "$($a.Role) assigned to $($a.What)"
    }

    # --- secrets --------------------------------------------------------------
    # The value goes in through a temp file, so it is never an argument in the
    # process list. RBAC propagation is eventually consistent, hence the retries.
    foreach ($s in @(
        @{ Name = $UsernameSecret; Value = $Username }
        @{ Name = $PasswordSecret; Value = $Password }
    )) {
        $tempFile = New-TemporaryFile
        try {
            [System.IO.File]::WriteAllText($tempFile.FullName, $s.Value, (New-Object System.Text.UTF8Encoding $false))
            $ok = $false
            foreach ($attempt in 1..12) {
                & az keyvault secret set --vault-name $Vault --name $s.Name --file $tempFile.FullName `
                    --encoding utf-8 --tags "AllowedEnvironments=$AllowedEnvironments" --output none 2>$null
                if ($LASTEXITCODE -eq 0) { $ok = $true; break }
                Write-Info "  $($s.Name): vault not ready yet (attempt $attempt), retrying in 10s"
                Start-Sleep -Seconds 10
            }
            if (-not $ok) {
                throw "Could not write secret '$($s.Name)' after 12 attempts. RBAC can take a few minutes to propagate on a brand new vault - re-run, or check your role assignments on $Vault."
            }
            Write-Ok "secret $($s.Name) written, tagged AllowedEnvironments=$AllowedEnvironments"
        }
        finally {
            if (Test-Path -LiteralPath $tempFile.FullName) { Remove-Item -LiteralPath $tempFile.FullName -Force }
        }
    }
}

function Get-GraphTokenAppOnly {
    param([string] $Tenant, [string] $App, [string] $Secret)
    $body = @{
        client_id     = $App
        client_secret = $Secret
        scope         = 'https://graph.microsoft.com/.default'
        grant_type    = 'client_credentials'
    }
    try {
        $r = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token" `
                               -ContentType 'application/x-www-form-urlencoded' -Body $body
    } catch {
        throw "Client credentials failed for app $App in tenant $Tenant. Check the id, the tenant and the secret VALUE (not the secret id). $($_.Exception.Message)"
    }
    if (-not $r.access_token) { throw 'Token endpoint returned no access_token.' }
    $r.access_token
}

function Resolve-SharePointLibraryId {
    param([string] $SiteUrl, [string] $LibraryName, [string] $Token)
    $h = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    $u = [uri] $SiteUrl
    try {
        $site = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$($u.Host):$($u.AbsolutePath)" -Headers $h
    }
    catch {
        throw ("Could not read site $SiteUrl via Graph: $($_.Exception.Message). " +
               'With an app-only token a 403 almost always means Sites.Read.All is missing as an APPLICATION permission, or admin consent was never granted.')
    }
    $lists = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/lists?`$select=id,displayName,name" -Headers $h
    # 'name' is the URL segment ('Shared Documents'), 'displayName' the title ('Documents')
    $hit = @($lists.value | Where-Object { $_.name -eq $LibraryName -or $_.displayName -eq $LibraryName })
    if ($hit.Count -eq 0) {
        throw ("No library '$LibraryName' on $SiteUrl. Available:`n" +
               (($lists.value | ForEach-Object { "    $($_.displayName)  (url: $($_.name))" }) -join "`n"))
    }
    if ($hit.Count -gt 1) { throw "'$LibraryName' matches $($hit.Count) lists on $SiteUrl." }
    $hit[0].id
}

function Add-FlowParameter {
    <# Declare an environment variable on the flow definition and return the
       expression that references it. #>
    param($Definition, [string] $Name, [string] $Value)
    $key  = "$Name ($Name)"
    $decl = [pscustomobject]@{
        defaultValue = $Value
        type         = 'String'
        metadata     = [pscustomobject]@{ schemaName = $Name }
    }
    if ($Definition.parameters.PSObject.Properties.Name -contains $key) {
        $Definition.parameters.$key = $decl
    } else {
        $Definition.parameters | Add-Member -NotePropertyName $key -NotePropertyValue $decl
    }
    "@parameters('$key')"
}

function Set-ToolInput {
    <# Agent tool definitions are YAML-ish; rewrite one property under inputs:. #>
    param([string] $File, [string] $Prop, [string] $Value)
    $lines    = [System.IO.File]::ReadAllLines($File)
    $inInputs = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^inputs:\s*$') { $inInputs = $true; continue }
        if ($inInputs -and $lines[$i] -match '^\S') { break }   # next top-level key
        if ($inInputs -and $lines[$i] -match ('^\s*propertyName:\s*' + [regex]::Escape($Prop) + '\s*$')) {
            for ($j = $i + 1; $j -lt [Math]::Min($i + 4, $lines.Count); $j++) {
                if ($lines[$j] -match '^(\s*)value:\s*.*$') {
                    $lines[$j] = "$($Matches[1])value: $Value"
                    [System.IO.File]::WriteAllLines($File, $lines)
                    return $true
                }
            }
            break
        }
    }
    $false
}

function Set-FnoEnvVar {
    <#
      Point one environmentvariabledefinition.xml at its secret, if it is an Fno
      one. Returns $null for every other variable, which is how callers know to
      skip it. The publisher prefix is matched dynamically - only the suffix is
      fixed.
    #>
    param([string] $LiteralPath, [string] $UsernameValue, [string] $PasswordValue)

    $xml = New-Object System.Xml.XmlDocument
    $xml.Load((Resolve-Path -LiteralPath $LiteralPath))
    $def    = $xml.DocumentElement
    $schema = $def.GetAttribute('schemaname')

    $value = switch -Regex ($schema) {
        '_FnoUsername$' { $UsernameValue; break }
        '_FnoPassword$' { $PasswordValue; break }
        default { return $null }
    }

    $node = $def.SelectSingleNode('defaultvalue')
    if (-not $node) {
        $node = $xml.CreateElement('defaultvalue')
        [void]$def.InsertBefore($node, $def.FirstChild)
    }
    $old = $node.InnerText
    $node.InnerText = $value

    # Save through an XmlWriter pinned to UTF-8 without a BOM. NOT $xml.Save(path),
    # which emits a BOM, and emphatically not $xml.Save(StringWriter), which stamps
    # the declaration encoding="utf-16" and makes pac fail with "There is no
    # Unicode byte order mark. Cannot switch to Unicode."
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding $false
    $settings.Indent   = $true
    $w = [System.Xml.XmlWriter]::Create($LiteralPath, $settings)
    try { $xml.Save($w) } finally { $w.Dispose() }

    [pscustomobject]@{ SchemaName = $schema; OldValue = $old; NewValue = $value }
}

function Invoke-SolutionStage {
    param(
        [string] $SrcZip, [string] $SiteUrl, [string] $DataverseUrl, [string] $Out,
        [string] $PackMode, [string] $PackType, [bool] $DoResolveLibrary, [string] $LibraryName,
        [string] $KeepAt, [string] $GraphToken,
        [bool] $DoFno, [string] $FnoUser, [string] $FnoPass
    )
    # The logic below was written under StrictMode; keep it scoped to this stage.
    Set-StrictMode -Version Latest

    $pac      = Resolve-Pac
    $changes  = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $tmp  = Join-Path ([IO.Path]::GetTempPath()) ('prepsol_' + [Guid]::NewGuid().ToString('N'))
    $work = if ($KeepAt) { $KeepAt } else { Join-Path $tmp 'src' }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }

    try {
        & $pac solution unpack --zipfile $SrcZip --folder $work --packagetype $PackType
        if ($LASTEXITCODE -ne 0) { throw "pac solution unpack failed (exit $LASTEXITCODE)" }
        Write-Info "unpacked $((Get-ChildItem -LiteralPath $work -Recurse -File).Count) files"

        # What the package actually contains decides which agents get shared
        # later, so nothing has to hardcode an agent name.
        $script:PackagedBots = @(Get-ChildItem -LiteralPath (Join-Path $work 'bots') -Directory |
                                 Select-Object -ExpandProperty Name)
        Write-Info "agents in package: $($script:PackagedBots -join ', ')"

        # --- the CSV flow: SharePoint site, and optionally the library id -----
        $flow = @(Get-ChildItem -LiteralPath (Join-Path $work 'Workflows') -Filter $CsvFlowPattern -File)
        if ($flow.Count -ne 1) {
            throw "Expected exactly one flow matching '$CsvFlowPattern', found $($flow.Count). Pass -CsvFlowPattern if the solution's flow was renamed."
        }
        $flowPath = $flow[0].FullName

        $json = Get-Content -LiteralPath $flowPath -Raw | ConvertFrom-Json
        $defn = $json.properties.definition

        if ($PackMode -eq 'envvar') {
            $siteValue = Add-FlowParameter -Definition $defn -Name $SharePointSiteVariable -Value $SiteUrl
        }
        else {
            # literal is the inverse of envvar: drop any environment variable
            # declarations so re-running over an envvar package comes out clean.
            $siteValue = $SiteUrl
            foreach ($p in @($defn.parameters.PSObject.Properties.Name | Where-Object { $_ -notlike '$*' })) {
                $defn.parameters.PSObject.Properties.Remove($p)
            }
        }

        $n = 0
        $tableParams = @()
        $folderHint  = $null
        foreach ($actionName in $defn.actions.PSObject.Properties.Name) {
            $action = $defn.actions.$actionName
            $inputs = $action.inputs
            # Compose actions carry a plain string in .inputs, not an object.
            if ($inputs -is [string] -or $null -eq $inputs) { continue }
            if ($inputs.PSObject.Properties.Name -notcontains 'parameters') { continue }
            $p     = $inputs.parameters
            $names = $p.PSObject.Properties.Name

            # Remember the library the flow writes into, e.g. '/Shared Documents/Test Cases'.
            if (-not $folderHint -and $names -contains 'folderPath' -and
                $p.folderPath -is [string] -and $p.folderPath.StartsWith('/')) {
                $folderHint = $p.folderPath
            }
            if ($names -contains 'table') { $tableParams += $p }

            if ($names -notcontains 'dataset') { continue }
            $cur = $p.dataset
            # Match either form we may have written before.
            if ($cur -is [string] -and ($cur -like '*sharepoint.com*' -or $cur -like '@parameters(*')) {
                $p.dataset = $siteValue
                $n++
            }
        }
        if ($n -eq 0) { throw "No SharePoint dataset values found in $($flow[0].Name)" }

        $libEnvDef = $null
        if ($tableParams.Count) {
            if ($DoResolveLibrary) {
                $libName =
                    if ($LibraryName)    { $LibraryName }
                    elseif ($folderHint) { ($folderHint.Trim('/') -split '/')[0] }
                    else                 { 'Shared Documents' }

                $libId = Resolve-SharePointLibraryId -SiteUrl $SiteUrl -LibraryName $libName -Token $GraphToken
                $changes.Add("library: resolved '$libName' on the target site -> $libId")

                $tableValue = $libId
                if ($PackMode -eq 'envvar') {
                    $tableValue = Add-FlowParameter -Definition $defn -Name $SharePointLibraryVariable -Value $libId
                    $libEnvDef  = @{ Name = $SharePointLibraryVariable; Value = $libId; Display = 'SharePoint Library Id' }
                }
                foreach ($tp in $tableParams) { $tp.table = $tableValue }
                $changes.Add("flow: set $($tableParams.Count) library id value(s)")
            }
            else {
                foreach ($tp in $tableParams) {
                    if ($tp.table -is [string] -and
                        $tp.table -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                        $warnings.Add("flow: 'table' is the library GUID $($tp.table), which belongs to whichever site this was exported from. Re-run with -ResolveLibraryId to look up the right one for $SiteUrl.")
                    }
                }
            }
        }

        Set-Utf8NoBom -LiteralPath $flowPath -Value ($json | ConvertTo-Json -Depth 100)
        $changes.Add("flow: set $n SharePoint site value(s) in $($flow[0].Name)")

        # --- the two agent tools ---------------------------------------------
        $tools = @(
            @{ Glob = $SharePointToolPattern; Prop = 'dataset';      Literal = $SiteUrl
               Ev = $SharePointSiteVariable;  Label = 'SharePoint file tool' }
            @{ Glob = $DataverseToolPattern;  Prop = 'organization'; Literal = $DataverseUrl
               Ev = $DataverseOrgVariable;    Label = 'Dataverse row tool' }
        )

        $evLinks = @()
        foreach ($t in $tools) {
            $dir = @(Get-ChildItem -LiteralPath (Join-Path $work 'botcomponents') -Filter $t.Glob -Directory)
            if ($dir.Count -ne 1) { throw "Expected exactly one $($t.Label) matching '$($t.Glob)', found $($dir.Count)" }
            $dataFile = Join-Path $dir[0].FullName 'data'
            $value = if ($PackMode -eq 'envvar') { "=Env.$($t.Ev)" } else { $t.Literal }

            if (Set-ToolInput -File $dataFile -Prop $t.Prop -Value $value) {
                $changes.Add("tool: set '$($t.Prop)' in $($t.Label)")
                if ($PackMode -eq 'envvar') { $evLinks += @{ Component = $dir[0].Name; Ev = $t.Ev } }
            }
            else {
                $warnings.Add("could not find '$($t.Prop)' input in $($t.Label) - left unchanged")
            }
        }

        # --- envvar mode: define the variables and link the tools -------------
        if ($PackMode -eq 'envvar') {
            $defs = @(
                @{ Name = $SharePointSiteVariable; Value = $SiteUrl;      Display = 'SharePoint Site URL' }
                @{ Name = $DataverseOrgVariable;   Value = $DataverseUrl; Display = 'Dataverse Org URL' }
            )
            if ($libEnvDef) { $defs += $libEnvDef }
            foreach ($d in $defs) {
                $dir = Join-Path $work "environmentvariabledefinitions\$($d.Name)"
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $xml = @"
<environmentvariabledefinition schemaname="$($d.Name)">
  <defaultvalue>$($d.Value)</defaultvalue>
  <displayname default="$($d.Display)">
    <label description="$($d.Display)" languagecode="1033" />
  </displayname>
  <introducedversion>1.0.0.0</introducedversion>
  <iscustomizable>1</iscustomizable>
  <isrequired>1</isrequired>
  <secretstore>0</secretstore>
  <type>100000000</type>
</environmentvariabledefinition>
"@
                Set-Utf8NoBom -LiteralPath (Join-Path $dir 'environmentvariabledefinition.xml') -Value $xml
                $changes.Add("env var: defined $($d.Name)")
            }

            $linkFile = Join-Path $work 'Assets\botcomponent_environmentvariabledefinitionset.xml'
            # Solutions with no env-var-using component yet have no link file at
            # all, so start one.
            if ($evLinks.Count -and -not (Test-Path -LiteralPath $linkFile)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $linkFile) -Force | Out-Null
                Set-Utf8NoBom -LiteralPath $linkFile `
                    -Value "<botcomponent_environmentvariabledefinitionset>`n</botcomponent_environmentvariabledefinitionset>"
                $changes.Add('env var: created the botcomponent link file (none existed)')
            }
            if ($evLinks.Count -and (Test-Path -LiteralPath $linkFile)) {
                $x = Get-Content -LiteralPath $linkFile -Raw
                $rows = ''
                foreach ($l in $evLinks) {
                    if ($x -match [regex]::Escape("environmentvariabledefinitionid.schemaname=`"$($l.Ev)`"")) { continue }
                    $rows += "  <botcomponent_environmentvariabledefinition botcomponentid.schemaname=`"$($l.Component)`" environmentvariabledefinitionid.schemaname=`"$($l.Ev)`">`n"
                    $rows += "    <iscustomizable>1</iscustomizable>`n"
                    $rows += "  </botcomponent_environmentvariabledefinition>`n"
                }
                if ($rows) {
                    $x = $x -replace '</botcomponent_environmentvariabledefinitionset>', ($rows + '</botcomponent_environmentvariabledefinitionset>')
                    Set-Utf8NoBom -LiteralPath $linkFile -Value $x
                    $changes.Add("env var: linked $($evLinks.Count) agent tool(s)")
                }
            }
            elseif ($evLinks.Count) {
                $warnings.Add('Assets\botcomponent_environmentvariabledefinitionset.xml missing - tools not linked')
            }
        }

        # --- drop search config for app modules the package does not ship ------
        $cust = @(
            (Join-Path $work 'Other\Customizations.xml')
            (Join-Path $work 'customizations.xml')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        $shipped = @()
        if ($cust) {
            $ctext = Get-Content -LiteralPath $cust -Raw
            $shipped = [regex]::Matches($ctext, '(?s)<AppModule>.*?<UniqueName>(.*?)</UniqueName>') |
                       ForEach-Object { $_.Groups[1].Value }
        }
        else {
            $warnings.Add('customizations manifest not found - assuming no app modules are shipped')
        }

        $searchRoot = Join-Path $work 'dvtablesearchs'
        $removedAny = $false
        if (Test-Path -LiteralPath $searchRoot) {
            foreach ($sf in Get-ChildItem -LiteralPath $searchRoot -Recurse -Filter 'dvtablesearch.xml' -File) {
                $sx = Get-Content -LiteralPath $sf.FullName -Raw
                $m = [regex]::Match($sx, '(?s)<m365appmoduleid>\s*<uniquename>(.*?)</uniquename>')
                if (-not $m.Success) { continue }
                $app = $m.Groups[1].Value
                if ($shipped -contains $app) { continue }

                $folder   = $sf.Directory
                $searchId = $folder.Name

                $entRoot = Join-Path $work 'dvtablesearchentities'
                if (Test-Path -LiteralPath $entRoot) {
                    foreach ($ef in Get-ChildItem -LiteralPath $entRoot -Recurse -Filter 'dvtablesearchentity.xml' -File) {
                        if ((Get-Content -LiteralPath $ef.FullName -Raw) -match [regex]::Escape($searchId)) {
                            Remove-Item -LiteralPath $ef.Directory.FullName -Recurse -Force
                        }
                    }
                }
                Remove-Item -LiteralPath $folder.FullName -Recurse -Force

                $dvLink = Join-Path $work 'Assets\botcomponent_dvtablesearchset.xml'
                if (Test-Path -LiteralPath $dvLink) {
                    $lx = Get-Content -LiteralPath $dvLink -Raw
                    $nx = [regex]::Replace($lx,
                        '(?is)\s*<botcomponent_dvtablesearch[^>]*' + [regex]::Escape($searchId) + '.*?</botcomponent_dvtablesearch>', '')
                    if ($nx -ne $lx) { Set-Utf8NoBom -LiteralPath $dvLink -Value $nx }
                }

                $changes.Add("import fix: removed search config for missing app '$app'")
                $removedAny = $true
            }
        }
        if (-not $removedAny) { $changes.Add('import fix: nothing to remove (no orphaned app search config)') }

        # --- Fno credentials: Key Vault secret REFERENCES, never values -------
        if ($DoFno) {
            $manifest = Join-Path $work 'Other\Solution.xml'
            if (-not (Test-Path -LiteralPath $manifest)) {
                throw 'Unpacked solution has no Other\Solution.xml, so the publisher prefix cannot be read.'
            }
            $prefix = $null
            foreach ($name in 'FnoUsername', 'FnoPassword') {
                $existing = Get-ChildItem -LiteralPath $work -Recurse -Filter 'environmentvariabledefinition.xml' -File |
                    Where-Object { ([xml](Get-Content -LiteralPath $_.FullName -Raw)).environmentvariabledefinition.schemaname -match "_$name$" }
                if ($existing) { continue }

                if (-not $prefix) {
                    $prefix = ([xml](Get-Content -LiteralPath $manifest -Raw)).SelectSingleNode('//CustomizationPrefix').InnerText
                    if (-not $prefix) { throw 'Solution.xml has no CustomizationPrefix, so the Fno variables cannot be named.' }
                }
                $schema = "${prefix}_$name"
                $dir    = Join-Path (Join-Path $work 'environmentvariabledefinitions') $schema
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $evXml = @"
<environmentvariabledefinition schemaname="$schema">
  <displayname default="$name">
    <label description="$name" languagecode="1033" />
  </displayname>
  <introducedversion>1.0.0.0</introducedversion>
  <iscustomizable>1</iscustomizable>
  <isrequired>0</isrequired>
  <secretstore>0</secretstore>
  <type>100000005</type>
</environmentvariabledefinition>
"@
                Set-Utf8NoBom -LiteralPath (Join-Path $dir 'environmentvariabledefinition.xml') -Value $evXml

                # Writing the file is not enough. A component not listed in
                # Solution.xml RootComponents is carried in the zip and then
                # ignored by the import. 380 is Environment Variable Definition.
                $sx = Get-Content -LiteralPath $manifest -Raw
                if ($sx -notmatch [regex]::Escape("schemaName=`"$schema`"")) {
                    $sx = $sx -replace '(\s*)</RootComponents>',
                                       "`$1  <RootComponent type=`"380`" schemaName=`"$schema`" behavior=`"0`" />`$1</RootComponents>"
                    Set-Utf8NoBom -LiteralPath $manifest -Value $sx.TrimEnd()
                }
                $changes.Add("fno: created $schema and registered it in the solution")
            }

            $touched = @(Get-ChildItem -LiteralPath $work -Recurse -Filter 'environmentvariabledefinition.xml' -File |
                         ForEach-Object { Set-FnoEnvVar -LiteralPath $_.FullName -UsernameValue $FnoUser -PasswordValue $FnoPass })
            if (-not $touched) { $warnings.Add('fno: no Fno username/password variables found or created') }
            foreach ($t in $touched) { $changes.Add("fno: $($t.SchemaName) -> $($t.NewValue)") }
        }

        # --- pack -------------------------------------------------------------
        if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
        & $pac solution pack --zipfile $Out --folder $work --packagetype $PackType
        if ($LASTEXITCODE -ne 0) { throw "pac solution pack failed (exit $LASTEXITCODE)" }
        # pac.cmd does not propagate exit codes, so a failed pack returns 0 and
        # the run would carry on and "import" a file that was never written. The
        # zip existing is the only honest proof. Long paths are the usual cause:
        # pac is still limited to 260 characters.
        if (-not (Test-Path -LiteralPath $Out)) {
            throw ("pac solution pack reported success but $Out does not exist. " +
                   'Check the output above - a path over 260 characters is the usual cause.')
        }

        Write-Host ''
        $changes  | ForEach-Object { Write-Info "- $_" }
        $warnings | ForEach-Object { Write-Warning $_ }
        Write-Ok "packed $Out  (mode: $PackMode)"
        if ($KeepAt) { Write-Info "unpacked source kept at $work" }
        if ($PackMode -eq 'envvar') {
            Write-Info 'NOTE: open the flow in the designer after import and confirm the SharePoint site field resolves to the environment variable.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Set-SolutionConnections {
    <#
      Platform already has the binding mechanism - the deployment settings file
      that `pac solution import --settings-file` consumes. What it does not have
      is a way to fill that file in. That is all this is:

          1. pac solution create-settings   lists every reference, ids blank
          2. create the connections that can be created
          3. pac connection list            what actually exists in the target
          4. match by connector, fill in the ids
          5. pac solution import --settings-file

      Matching is by connector id. One connection for a connector is taken
      silently; several is an ambiguity this refuses to guess at - it prompts, or
      takes a -Connection pin so the run stays unattended.
    #>
    param(
        [string] $Zip, [string] $EnvironmentUrl, [string] $EnvId, [string] $Settings,
        [hashtable] $Pins, [bool] $DoDataverse, [bool] $DoSharePoint,
        [string] $AppId, [string] $Tenant, [string] $AppSecret,
        [string] $DataverseName, [string] $SharePointName, [int] $ConsentTimeout,
        [bool] $DoImport
    )

    $pac = Resolve-Pac

    # --- the references the solution declares --------------------------------
    if (Test-Path -LiteralPath $Settings) { Remove-Item -LiteralPath $Settings -Force }
    & $pac solution create-settings --solution-zip $Zip --settings-file $Settings 2>&1 | ForEach-Object { Write-Info $_ }
    # pac.cmd returns 0 even where it printed an error, so prove the file instead.
    if (-not (Test-Path -LiteralPath $Settings)) {
        throw "pac solution create-settings reported success but $Settings is not there."
    }

    $settingsObj = Get-Content -LiteralPath $Settings -Raw | ConvertFrom-Json
    $refs = @($settingsObj.ConnectionReferences)
    if (-not $refs) { throw 'The solution declares no connection references - nothing to bind.' }
    Write-Info "$($refs.Count) connection reference(s) in the solution."

    # create-settings writes "Value": "" for every environment variable, and the
    # import then rejects its own file with "Environment variable value can't be
    # an empty string". An absent entry is fine - the value baked into the
    # solution is used - so drop the blanks rather than inventing values.
    $vars  = @($settingsObj.EnvironmentVariables)
    $empty = @($vars | Where-Object { -not $_.Value })
    if ($empty) {
        $settingsObj.EnvironmentVariables = @($vars | Where-Object { $_.Value })
        Write-Info ("dropped $($empty.Count) environment variable(s) with no value, keeping the solution's own: " +
                    ($empty.SchemaName -join ', '))
    }

    # --- create connections ---------------------------------------------------
    $paHeaders = $null
    $envFilter = $null
    if ($DoDataverse -or $DoSharePoint) {
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is needed to create a connection.' }
        if (-not (az account show 2>$null)) { throw 'No Azure CLI session. Run: az login' }

        $paToken = az account get-access-token --resource 'https://service.powerapps.com/' --query accessToken -o tsv
        if (-not $paToken) { throw 'Could not get a Power Apps token.' }
        $paHeaders = @{ Authorization = "Bearer $paToken"; Accept = 'application/json' }

        if (-not $EnvId) {
            # instanceApiUrl is https://org65efd8ed.api.crm.dynamics.com while
            # callers pass https://org65efd8ed.crm.dynamics.com, so match on the
            # org name only.
            $org = ([uri]$EnvironmentUrl).Host -replace '\..*$', ''
            $all = (Invoke-RestMethod -Headers $paHeaders `
                        -Uri 'https://api.powerapps.com/providers/Microsoft.PowerApps/environments?api-version=2016-11-01').value
            $hit = @($all | Where-Object {
                $_.properties.linkedEnvironmentMetadata.instanceApiUrl -and
                (([uri]$_.properties.linkedEnvironmentMetadata.instanceApiUrl).Host -replace '\..*$', '') -eq $org })
            if ($hit.Count -ne 1) { throw "Could not resolve $EnvironmentUrl to one environment id ($($hit.Count) matched). Pass -EnvironmentId." }
            $EnvId = $hit[0].name
        }
        Write-Info "environment $EnvId"

        # Every connection call wants this filter; without it the API answers
        # MissingEnvironmentFilter.
        $envFilter = '&%24filter=' + [uri]::EscapeDataString("environment eq '$EnvId'")
    }

    if ($DoDataverse) {
        Write-Info 'Creating a Dataverse connection (service principal)...'
        if (-not $AppId)     { throw 'Creating the Dataverse connection needs -DataverseAppId.' }
        if (-not $Tenant)    { throw 'Creating the Dataverse connection needs -DataverseTenantId.' }
        if (-not $AppSecret) { throw 'Creating the Dataverse connection needs -DataverseAppSecret.' }

        $newId = (New-Guid).Guid.Replace('-', '')
        # The braces around $newId are load-bearing: '?' is legal in a PowerShell
        # variable name, so "$newId?api-version" reads as an empty variable.
        $url = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/' +
               "shared_commondataserviceforapps/connections/${newId}?api-version=2016-11-01" + $envFilter

        $body = @{
            properties = @{
                displayName = $DataverseName
                environment = @{
                    id   = "/providers/Microsoft.PowerApps/environments/$EnvId"
                    name = $EnvId
                }
                connectionParametersSet = @{
                    name   = 'ServicePrincipalOauth'
                    values = @{
                        token                = @{ value = 'https://global.consent.azure-apim.net/redirect/commondataserviceforapps' }
                        'token:clientId'     = @{ value = $AppId }
                        'token:clientSecret' = @{ value = $AppSecret }
                        'token:TenantId'     = @{ value = $Tenant }
                        'token:grantType'    = @{ value = 'client_credentials' }
                    }
                }
            }
        } | ConvertTo-Json -Depth 20

        Write-Info "PUT $DataverseName as app $AppId (secret not logged)"
        try {
            Invoke-RestMethod -Method Put -Uri $url -Headers $paHeaders -ContentType 'application/json' -Body $body | Out-Null
        } catch {
            $detail = $_.ErrorDetails.Message -replace '(?i)"token:clientSecret"\s*:\s*\{[^}]*\}', '"token:clientSecret":"<REDACTED>"'
            throw "Creating the connection failed: $($_.Exception.Message)`n$detail"
        }

        # A bad secret still yields 201, with the failure only in statuses, so
        # read back rather than trusting the PUT.
        $made   = Invoke-RestMethod -Uri $url -Headers $paHeaders
        $status = $made.properties.statuses | Select-Object -First 1
        if ($status.status -ne 'Connected') {
            throw "Connection $newId was created but is '$($status.status)': $($status.error.message). Check the secret, and that $AppId is an application user in this environment."
        }
        Write-Ok "created $newId ($DataverseName) Connected"
        $Pins['shared_commondataserviceforapps'] = $newId
    }

    if ($DoSharePoint) {
        Write-Info 'Creating a SharePoint connection...'
        # SharePoint has no service principal option, so the connection has to be
        # consented to by a person. What can be automated is everything around
        # that: the shell, the consent link and the polling. The human part is
        # one sign-in, usually one click.
        Assert-AzUserSession 'Creating the first SharePoint connection in an environment'
        $newSpId = 'shared-sharepointonl-' + [Guid]::NewGuid().ToString()
        $spUrl   = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/' +
                   "shared_sharepointonline/connections/${newSpId}?api-version=2016-11-01" + $envFilter

        $spBody = @{ properties = @{
            displayName          = $SharePointName
            environment          = @{ id = "/providers/Microsoft.PowerApps/environments/$EnvId"; name = $EnvId }
            connectionParameters = @{}
        } } | ConvertTo-Json -Depth 10

        Invoke-RestMethod -Method Put -Uri $spUrl -Headers $paHeaders -ContentType 'application/json' -Body $spBody | Out-Null
        Write-Info "created $newSpId unauthenticated, asking for a consent link"

        # Signing in at the consent link is what authenticates the connection;
        # the portal's follow-up confirmConsentCode call is bookkeeping, not a
        # requirement. So there is nothing to catch - ask the service, and poll.
        $redirect = 'https://make.powerapps.com/connection/oauth/redirect?oauthPopupId=' + [Guid]::NewGuid()
        $linkUrl  = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/' +
                    "shared_sharepointonline/connections/$newSpId/getConsentLink?api-version=2016-11-01" + $envFilter
        $link = (Invoke-RestMethod -Method Post -Uri $linkUrl -Headers $paHeaders -ContentType 'application/json' `
                    -Body (@{ redirectUrl = $redirect } | ConvertTo-Json)).consentLink
        if (-not $link) { throw 'The consent service returned no link.' }

        Write-Host ''
        Write-Host '    A browser window is opening. Sign in as the account the flows should run as.' -ForegroundColor Yellow
        Write-Host "    If it does not open, paste this in yourself:`n    $link"
        Start-Process $link

        $deadline = (Get-Date).AddSeconds($ConsentTimeout)
        do {
            Start-Sleep -Seconds 3
            $spStatus = (Invoke-RestMethod -Uri $spUrl -Headers $paHeaders).properties.statuses | Select-Object -First 1
            Write-Info "waiting for sign-in... $($spStatus.status)"
        } while ($spStatus.status -ne 'Connected' -and (Get-Date) -lt $deadline)

        if ($spStatus.status -ne 'Connected') {
            throw ("Still '$($spStatus.status)' after $ConsentTimeout seconds. " +
                   "Connection $newSpId is left behind - delete it in make.powerapps.com, or re-run with " +
                   "-SkipCreateSharePoint -Connection shared_sharepointonline=$newSpId once you have signed it in there.")
        }

        $spMade = Invoke-RestMethod -Uri $spUrl -Headers $paHeaders
        Write-Ok "created $newSpId ($($spMade.properties.displayName)) Connected as $($spMade.properties.authenticatedUser.name)"
        $Pins['shared_sharepointonline'] = $newSpId
    }

    # --- what exists in the target -------------------------------------------
    $listed = & $pac connection list --environment $EnvironmentUrl 2>&1 | ForEach-Object { "$_" }
    $conns  = @(ConvertFrom-PacConnectionList $listed)
    if (-not $conns) {
        $listed | ForEach-Object { Write-Info $_ }
        throw "No connections were listed. Check 'pac auth list' points at $EnvironmentUrl."
    }
    $conns | Group-Object Connector | ForEach-Object { Write-Info "$($_.Name): $($_.Count) connection(s)" }

    # --- bind -----------------------------------------------------------------
    foreach ($r in $refs) {
        $connector = $r.ConnectorId -replace '^.*/', ''

        if ($Pins.ContainsKey($connector)) {
            $r.ConnectionId = $Pins[$connector]
            Write-Info "$connector -> $($r.ConnectionId)  (pinned)"
            continue
        }

        $candidates = @($conns | Where-Object { $_.Connector -eq $connector -and $_.Status -eq 'Connected' })

        if ($candidates.Count -eq 0) {
            throw @"
No connected '$connector' connection exists in $EnvironmentUrl.

Create one first - these connectors sign in as a user, so the first one needs a
human to consent:

    Dataverse    re-run without -SkipCreateDataverse
    SharePoint   re-run without -SkipCreateSharePoint, or create one at
                 make.powerapps.com -> Connections -> New connection

then run this again.
"@
        }

        if ($candidates.Count -eq 1) {
            $r.ConnectionId = $candidates[0].Id
            Write-Info "$connector -> $($r.ConnectionId)"
            continue
        }

        # Several match. Guessing here binds the agent to whichever connection
        # the API happened to return first, which is how a tool ends up reading
        # the wrong site, so ask instead.
        Write-Host "`n    $($r.LogicalName)"
        Write-Host "    $($candidates.Count) '$connector' connections match:"
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ('      [{0}] {1}  {2}' -f ($i + 1), $candidates[$i].Id, $candidates[$i].Name)
        }
        $answer = (Read-Host "    Pick 1-$($candidates.Count)").Trim()
        $pick = 0
        if (-not [int]::TryParse($answer, [ref]$pick) -or $pick -lt 1 -or $pick -gt $candidates.Count) {
            throw "'$answer' is not one of 1-$($candidates.Count). Pass -Connection $connector=<id> to run unattended."
        }
        $r.ConnectionId = $candidates[$pick - 1].Id
        Write-Info "$connector -> $($r.ConnectionId)"
    }

    $blank = @($refs | Where-Object { -not $_.ConnectionId })
    if ($blank) { throw "Still unbound: $($blank.LogicalName -join ', ')" }

    # UTF-8 without a BOM: pac reads this file as JSON and a BOM has bitten this
    # pipeline before.
    [System.IO.File]::WriteAllText($Settings, ($settingsObj | ConvertTo-Json -Depth 20),
                                   (New-Object System.Text.UTF8Encoding $false))
    Write-Ok "wrote $Settings"

    # --- import ---------------------------------------------------------------
    if (-not $DoImport) {
        Write-Info "Import skipped. Import with:  pac solution import --environment $EnvironmentUrl --path $Zip --settings-file $Settings"
        return
    }

    $out = & $pac solution import --environment $EnvironmentUrl --path $Zip `
                --settings-file $Settings --publish-changes --force-overwrite `
                --activate-plugins --max-async-wait-time 60 2>&1 | ForEach-Object { "$_" }
    $out | ForEach-Object { Write-Info $_ }
    if ($LASTEXITCODE -ne 0 -or ($out -match '^\s*Error:')) {
        # Carry pac's own lines into the exception. Without them the throw is all
        # the caller sees once the console has scrolled.
        $why = @($out | Where-Object { $_ -match '(?i)error|fail|unable|cannot|missing' }) -join "`n  "
        throw ("Import failed.`n  " + $why +
               "`n`nThe settings file is at $Settings - it is reusable, fix the cause and re-run.")
    }
    Write-Ok 'import succeeded.'
}

# ============================================================================
# stage 2 - machine and CUA configuration
# ============================================================================

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

    .\Run-HandOver.ps1 -SkipPrepare -Force

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

function New-CuaConnection {
    <#
      PUTs a shared_computeroperator connection carrying the machine GROUP id and
      the Windows credential, then reads it back - targetId is the whole point of
      the connection and the PUT body is not documented to echo the parameter set.
      Returns the new connection id.
    #>
    param([string] $PowerAppsToken, [string] $GroupId, [string] $Username, [string] $Password)

    # Guarded here and not in Get-DelegatedToken: the token itself is fine
    # app-only and the 4.1-4.3 binding writes work with it. It is this PUT,
    # and only this PUT, that the connectivity service refuses with code 10006.
    Assert-AzUserSession 'Creating the Computer Use connection'

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
        # An app-only session gets this far and then fails much later, at the
        # gateway's idtyp check, with nothing to point at. Fail here instead.
        Assert-AzUserSession 'Step 4.4, setting the agent authentication to Custom Entra'
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


# ============================================================================
# Invoke-PrepareStage
#   Transplanted verbatim from the verified Prepare-Sol.ps1.
#   Body is NOT re-indented: it contains here-strings whose terminator must
#   sit at column 0.
# ============================================================================
function Invoke-PrepareStage {
try {
    Write-Stage 'Step 1 - Solution preparation'

    # --- collect every input up front, so nothing prompts mid-run -------------
    if ($SolutionPath -and -not (Test-Path -LiteralPath $SolutionPath -PathType Leaf)) {
        throw "Not a file: $SolutionPath"
    }
    if (-not $SolutionUrl -and -not $SolutionPath) {
        $SolutionUrl = Read-RequiredValue 'Solution package https URL' (Get-Fallback $SolutionUrl 'SolutionUrl')
    }
    if ($SolutionUrl -and $SolutionUrl -notmatch '^https://') {
        throw "Refusing a non-https solution source: $SolutionUrl"
    }

    $OrgUrl = (Read-RequiredValue 'Target Dataverse org URL (https://org....crm.dynamics.com)' (Get-Fallback $OrgUrl 'OrgUrl')).TrimEnd('/')
    if ($OrgUrl -notmatch '^https://[^/]+\.dynamics\.com$') {
        throw "Dataverse org URL should look like https://<org>.crm.dynamics.com, got: $OrgUrl"
    }

    $SharePointUrl = (Read-RequiredValue 'SharePoint site URL (https://<tenant>.sharepoint.com/sites/<site>)' (Get-Fallback $SharePointUrl 'SharePointUrl')).TrimEnd('/')
    if ($SharePointUrl -notmatch '^https://[^/]+\.sharepoint\.com/sites/.+') {
        throw "SharePoint URL should look like https://<tenant>.sharepoint.com/sites/<site>, got: $SharePointUrl"
    }

    if (-not $EnvironmentId) { $EnvironmentId = $State.EnvironmentId }

    if (-not $SkipKeyVault) {
        $SubscriptionId        = Read-RequiredValue  'Azure subscription id'                                (Get-Fallback $SubscriptionId        'SubscriptionId')
        $ResourceGroupName     = Read-RequiredValue  'Resource group name'                                  (Get-Fallback $ResourceGroupName     'ResourceGroupName')
        $Location              = Read-RequiredValue  'Azure region (e.g. East US)'                          (Get-Fallback $Location              'Location')
        $KeyVaultName          = Read-RequiredValue  'Key Vault name (globally unique)'                     (Get-Fallback $KeyVaultName          'KeyVaultName')
        # The AllowedEnvironments tag is the ENVIRONMENT id, not the tenant id.
        $AllowedEnvironmentTag = Resolve-AllowedEnvironments -EnvironmentId $EnvironmentId -TenantId $TenantId `
                                    -Tag (Get-Fallback $AllowedEnvironmentTag 'AllowedEnvironmentTag')
        Write-Info "AllowedEnvironments tag: $AllowedEnvironmentTag"
        $FnoUsername           = Read-RequiredValue  'F&O username'                                         (Get-Fallback $FnoUsername           'FnoUsername')
        $FnoPassword           = Read-RequiredSecret 'F&O password'                                         $FnoPassword
    }

    # The environment variables must point at the vault whether or not this run
    # created it, so these are needed either way.
    if (-not $SkipFno) {
        if (-not $FnoUsernameSecretUri -or -not $FnoPasswordSecretUri) {
            $SubscriptionId    = Read-RequiredValue 'Azure subscription id' (Get-Fallback $SubscriptionId    'SubscriptionId')
            $ResourceGroupName = Read-RequiredValue 'Resource group name'   (Get-Fallback $ResourceGroupName 'ResourceGroupName')
            $KeyVaultName      = Read-RequiredValue 'Key Vault name'        (Get-Fallback $KeyVaultName      'KeyVaultName')
        }
        if (-not $FnoUsernameSecretUri) {
            $FnoUsernameSecretUri = New-SecretReference -Subscription $SubscriptionId -ResourceGroup $ResourceGroupName -Vault $KeyVaultName -Secret $UsernameSecretName
        }
        if (-not $FnoPasswordSecretUri) {
            $FnoPasswordSecretUri = New-SecretReference -Subscription $SubscriptionId -ResourceGroup $ResourceGroupName -Vault $KeyVaultName -Secret $PasswordSecretName
        }
        # Fail before unpacking anything if the references are malformed.
        # Dataverse otherwise accepts the import and reports "This variable
        # didn't save properly" with no clue which value was wrong.
        foreach ($v in @{ Username = $FnoUsernameSecretUri; Password = $FnoPasswordSecretUri }.GetEnumerator()) {
            if ($v.Value -notmatch $SecretRefPattern) {
                throw "Fno $($v.Key) is not a valid Key Vault secret reference: $($v.Value)`n$SecretRefHint"
            }
        }
    }

    if (-not $SkipCreateDataverse) {
        $DataverseAppId     = Read-RequiredValue  'Dataverse connection app (client) id' (Get-Fallback $DataverseAppId    'DataverseAppId')
        $DataverseTenantId  = Read-RequiredValue  'Tenant id'                            (Get-Fallback $DataverseTenantId 'TenantId')
        $DataverseAppSecret = Read-RequiredSecret 'Dataverse app client secret'          $DataverseAppSecret
    }

    $graphSecretPlain = $null
    if ($ResolveLibraryId) {
        $ClientId     = Read-RequiredValue  'Graph app registration client id' (Get-Fallback $ClientId 'GraphClientId')
        $TenantId     = Read-RequiredValue  'Tenant id'                        (Get-Fallback $TenantId 'TenantId')
        $ClientSecret = Read-RequiredSecret 'Graph app client secret'          $ClientSecret
    }

    # 'connector=id' pairs; the connector name is normalised so both
    # shared_sharepointonline and the full /providers/... form work. -File hands
    # an array parameter through as one comma-joined string, so split it back.
    $Connection = @($Connection | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $pins = @{}
    foreach ($c in $Connection) {
        if ($c -notmatch '^(.+?)=(.+)$') { throw "-Connection wants 'connector=id', got '$c'." }
        $pins[($Matches[1] -replace '^.*/', '').Trim()] = $Matches[2].Trim()
    }

    if (-not $SettingsFile) { $SettingsFile = Join-Path $PSScriptRoot 'deploy-settings.json' }

    Write-Info "target      $OrgUrl"
    Write-Info "sharepoint  $SharePointUrl"
    Write-Info "source      $(if ($SolutionUrl) { $SolutionUrl } else { $SolutionPath })"
    Write-Info "vault       $(if ($SkipKeyVault) { "$KeyVaultName (reused, not created)" } else { $KeyVaultName })"

    $work = Join-Path ([IO.Path]::GetTempPath()) ('handover_sol_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        # ======================================================================
        # 1.1  fetch
        # ======================================================================
        Write-Stage '1.1  Download the solution package'
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

        if (-not $OutFile) {
            $OutFile = Join-Path (Get-Location).Path ([IO.Path]::GetFileNameWithoutExtension($src) + '_Changed.zip')
        }

        # ======================================================================
        # 1.2  Key Vault and secrets
        # ======================================================================
        if ($SkipKeyVault) {
            Write-Stage '1.2  Key Vault (skipped)'
            Write-Info 'The vault and both secrets must already exist - the environment variables still point at them.'
        } else {
            Write-Stage '1.2  Create the Key Vault and store the F&O credentials'
            $plain = ConvertFrom-Secure $FnoPassword
            try {
                New-FnoKeyVault -Subscription $SubscriptionId -ResourceGroup $ResourceGroupName `
                    -Region $Location -Vault $KeyVaultName -AllowedEnvironments $AllowedEnvironmentTag `
                    -UsernameSecret $UsernameSecretName -PasswordSecret $PasswordSecretName `
                    -Username $FnoUsername -Password $plain
            }
            finally { $plain = $null }
        }

        # ======================================================================
        # 1.3  retarget, point the environment variables at the vault, repack
        # ======================================================================
        Write-Stage '1.3  Retarget values, point environment variables at the vault, repack'
        $graphToken = $null
        if ($ResolveLibraryId) {
            $graphSecretPlain = ConvertFrom-Secure $ClientSecret
            $graphToken = Get-GraphTokenAppOnly -Tenant $TenantId -App $ClientId -Secret $graphSecretPlain
            $graphSecretPlain = $null
            Write-Info "graph token acquired app-only for $ClientId"
        }

        Invoke-SolutionStage -SrcZip $src -SiteUrl $SharePointUrl -DataverseUrl $OrgUrl -Out $OutFile `
            -PackMode $Mode -PackType $PackageType -DoResolveLibrary ([bool]$ResolveLibraryId) `
            -LibraryName $Library -KeepAt $KeepSource -GraphToken $graphToken `
            -DoFno (-not $SkipFno) -FnoUser $FnoUsernameSecretUri -FnoPass $FnoPasswordSecretUri

        if (-not (Test-Path -LiteralPath $OutFile)) { throw "Packing reported success but $OutFile is not there." }

        # ======================================================================
        # 1.4  connections, settings file, import
        # ======================================================================
        Write-Stage '1.4  Create the Dataverse and SharePoint connections, then import'
        if (-not $SkipCreateSharePoint) {
            Write-Info 'SharePoint has no service principal option - a browser will open for one interactive sign-in.'
        }
        $dvSecretPlain = ConvertFrom-Secure $DataverseAppSecret
        try {
            Set-SolutionConnections -Zip $OutFile -EnvironmentUrl $OrgUrl -EnvId $EnvironmentId `
                -Settings $SettingsFile -Pins $pins `
                -DoDataverse (-not $SkipCreateDataverse) -DoSharePoint (-not $SkipCreateSharePoint) `
                -AppId $DataverseAppId -Tenant $DataverseTenantId -AppSecret $dvSecretPlain `
                -DataverseName $DataverseConnectionName -SharePointName $SharePointConnectionName `
                -ConsentTimeout $ConsentTimeoutSeconds -DoImport (-not $SkipImport)
        }
        finally { $dvSecretPlain = $null }
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
        $pac = Resolve-Pac
        & $pac solution list --environment $OrgUrl 2>&1 | ForEach-Object { Write-Info $_ }
        Write-Gate 'Confirm your solution is listed above before stage 2 runs.'
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
        FnoUsername           = $FnoUsername
        DataverseAppId        = $DataverseAppId
        TenantId              = $DataverseTenantId
        SettingsFile          = $SettingsFile
        PackedSolution        = $OutFile
        Agents                = $script:PackagedBots
    }

    Write-Stage 'Step 1 complete'
    Write-Info 'Next: stage 2 - machine and CUA (needs Administrator, on the VM itself)'
}
catch {
    Write-Host "`nSTEP 1 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
}

# ============================================================================
# Invoke-MachineStage
#   Transplanted verbatim from the verified Machine-and-Cua.ps1.
#   Body is NOT re-indented: it contains here-strings whose terminator must
#   sit at column 0.
# ============================================================================
function Invoke-MachineStage {
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
    Write-Info 'Next: stage 3 - share and publish'
}
catch {
    Write-Host "`nSTEP 2 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
}

# ============================================================================
# Invoke-ShareStage
#   Transplanted verbatim from the verified Share-Agents.ps1. Wrapping it in a function is load-bearing: its own Invoke-Dv and Resolve-Pac are defined inside the try block, so nesting them keeps them from overriding the machine stage versions at script scope.
#   Body is NOT re-indented: it contains here-strings whose terminator must
#   sit at column 0.
# ============================================================================
function Invoke-ShareStage {
try {
    Write-Stage 'Step 3 - Share and publish the agents'

    # Start from a real array. A pipeline that yields nothing gives $null, and
    # $null += 'a' then += 'b' concatenates into ONE string whose .Count is 1, so
    # a guard built that way never fires and two modes both run.
    $modes = @()
    if ($UserEmail)       { $modes += '-UserEmail' }
    if ($RevokeUserEmail) { $modes += '-RevokeUserEmail' }
    if ($Everyone)        { $modes += '-Everyone' }
    if ($RevokeEveryone)  { $modes += '-RevokeEveryone' }
    if ($modes.Count -gt 1) { throw "Pass only one grant at a time, got: $($modes -join ', ')" }

    $OrgUrl = (Read-RequiredValue 'Target Dataverse org URL (https://org....crm.dynamics.com)' (Get-Fallback $OrgUrl 'OrgUrl')).TrimEnd('/')
    if ($OrgUrl -notmatch '^https://') { throw "-OrgUrl must be an https org URL, got: $OrgUrl" }

    # Accept 'a,b' and 'a b' as well as a real array. "pwsh -File script.ps1
    # -Agent a,b" hands the whole thing over as ONE string, unlike a call from a
    # prompt, so split either way and both invocations behave the same.
    if (-not $Agent -or $Agent.Count -eq 0) {
        if ($State.Agents) { $Agent = @($State.Agents) }
        else {
            $Agent = @(Read-RequiredValue 'Agent schema names, comma separated (e.g. cr720_Agent1TestScript,cr720_Agent2UITesting)' $null)
        }
    }
    $Agent = @($Agent | ForEach-Object { $_ -split '[,\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $Agent.Count) { throw 'No agent schema names to act on.' }

    # --- auth -----------------------------------------------------------------
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) not found - install from https://aka.ms/azure-cli and run `az login`.'
    }
    # --query/-o tsv so the token never lands in a file or the process list.
    $token = az account get-access-token --resource $OrgUrl --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "az could not get a token for $OrgUrl. Run 'az login' in the same tenant as the environment.`n$token"
    }
    $api     = "$OrgUrl/api/data/v9.2"
    $headers = @{ Authorization = "Bearer $token"; Accept = 'application/json'; 'Content-Type' = 'application/json' }

    function Invoke-Dv {
        param([string] $Path, [string] $Method = 'Get', $Body)
        $call = @{ Method = $Method; Uri = "$api/$Path"; Headers = $headers }
        if ($null -ne $Body) { $call.Body = ($Body | ConvertTo-Json -Depth 6) }
        try { Invoke-RestMethod @call }
        catch {
            # Dataverse explains itself in the body; the status code alone cannot
            # tell "no privilege" from "no such row". PS 7 exposes it on
            # ErrorDetails, 5.1 often only in the raw stream.
            $body = $_.ErrorDetails.Message
            if (-not $body) {
                try {
                    $s = $_.Exception.Response.GetResponseStream(); $s.Position = 0
                    $body = (New-Object System.IO.StreamReader($s)).ReadToEnd()
                } catch { $body = $_.Exception.Message }
            }
            $msg = $body
            try { $msg = ($body | ConvertFrom-Json).error.message } catch { }
            throw "$Method $($Path -replace '\?.*$', '') failed: $msg"
        }
    }

    function Resolve-DvUser {
        param([string] $Email)
        $e = $Email.Trim().Replace("'", "''")
        $u = (Invoke-Dv ("systemusers?`$select=systemuserid,fullname,domainname,_businessunitid_value&`$filter=" +
                         "domainname eq '$e' or internalemailaddress eq '$e'")).value
        if (-not $u)        { throw "No user '$e' in $OrgUrl. They must already exist in this environment - add them in the Power Platform admin center first." }
        if ($u.Count -gt 1) { throw "'$e' matched $($u.Count) users." }
        $u
    }

    function Get-SharedPrincipals {
        param([hashtable] $Target)
        (Invoke-Dv ('RetrieveSharedPrincipalsAndAccess(Target=@t)?@t=' +
                    [uri]::EscapeDataString(($Target | ConvertTo-Json -Compress)))).PrincipalAccesses
    }

    function Resolve-Pac {
        $pac = (Get-Command pac, pac.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $pac) { $pac = "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\pac.cmd" }
        if (-not (Test-Path $pac)) {
            throw 'Power Platform CLI (pac) not found - install from https://aka.ms/PowerAppsCLI. The sharing change is already written; publish from the designer.'
        }
        $pac
    }

    # ==========================================================================
    # one agent: report, grant, publish
    # ==========================================================================
    function Invoke-AgentStage {
        param([string] $Bot)

        $row = (Invoke-Dv "bots?`$select=botid,name,accesscontrolpolicy,authorizedsecuritygroupids,publishedon&`$filter=schemaname eq '$Bot'").value
        if (-not $row)        { throw "No agent with schema name '$Bot' in $OrgUrl. Schema name, not display name." }
        if ($row.Count -gt 1) { throw "'$Bot' matched $($row.Count) agents." }

        Write-Info "$($row.name) [$Bot]"
        Write-Info "  policy      $($row.accesscontrolpolicy) $($PolicyName[[int]$row.accesscontrolpolicy])  $($row.authorizedsecuritygroupids)"
        Write-Info "  publishedon $($row.publishedon)"

        $target = @{ '@odata.id' = "bots($($row.botid))" }

        # --- report only ------------------------------------------------------
        if ($modes.Count -eq 0) {
            Write-Info '  shared with'
            $principals = @(Get-SharedPrincipals $target)
            if (-not $principals.Count) { Write-Info '    (nobody - only the owner team)' }
            foreach ($p in $principals) {
                $id   = $p.Principal.ownerid
                $type = $p.Principal.'@odata.type' -replace '.*\.', ''
                $who  = if ($type -eq 'systemuser') { (Invoke-Dv "systemusers($id)?`$select=domainname").domainname }
                        else { "$((Invoke-Dv "teams($id)?`$select=name").name) (team)" }
                Write-Info "    $who - $($p.AccessMask)"
            }
            return
        }

        # --- everyone ---------------------------------------------------------
        if ($Everyone) {
            Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{ accesscontrolpolicy = 0; authorizedsecuritygroupids = $null } | Out-Null
            Write-Ok "policy set to 0 $($PolicyName[0])"
        }

        # --- revoke everyone --------------------------------------------------
        if ($RevokeEveryone) {
            # The mirror of -Everyone: withdraw the org-wide grant by moving the
            # policy to Copilot readers. Individual row shares survive on purpose -
            # they are separate grants, and clearing them is -RevokeUserEmail's
            # job, one user at a time.
            Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{ accesscontrolpolicy = 1; authorizedsecuritygroupids = $null } | Out-Null
            Write-Ok "org-wide access withdrawn. Policy set to 1 $($PolicyName[1])"
            $left = @(Get-SharedPrincipals $target | Where-Object { $_.Principal.'@odata.type' -match 'systemuser' })
            if ($left.Count) {
                Write-Info '  these users keep access through an individual share:'
                foreach ($p in $left) { Write-Info "    $((Invoke-Dv "systemusers($($p.Principal.ownerid))?`$select=domainname").domainname)" }
                Write-Info '  clear each with -RevokeUserEmail, or leave them if they should keep it.'
            } else {
                Write-Info '  no individual user shares remain - only the owner team can use the agent.'
            }
        }

        # --- one user ---------------------------------------------------------
        if ($UserEmail) {
            $user = Resolve-DvUser $UserEmail
            Write-Info "share with: $($user.fullname) <$($user.domainname)>"

            # 1. prvReadbot, the privilege that lets the user see the agent at
            #    all. Only grant a role if none of theirs already carries it -
            #    Environment Maker is environment-wide, and Bot Author / Bot
            #    Viewer / Agent Viewer carry it too.
            $userRoles  = (Invoke-Dv "systemusers($($user.systemuserid))/systemuserroles_association?`$select=name,roleid").value
            $prvReadBot = (Invoke-Dv "privileges?`$select=privilegeid&`$filter=name eq 'prvReadbot'").value[0].privilegeid
            $holder     = $userRoles | Where-Object {
                (Invoke-Dv "RetrieveRolePrivilegesRole(RoleId=$($_.roleid))").RolePrivileges.PrivilegeId -contains $prvReadBot
            } | Select-Object -First 1

            if ($holder) {
                Write-Info "  role   $($holder.name) already carries prvReadbot"
            } else {
                $role = (Invoke-Dv ("roles?`$select=roleid&`$filter=name eq 'Environment Maker' and _businessunitid_value eq $($user._businessunitid_value)")).value
                if (-not $role) { throw "No Environment Maker role in the user's business unit. Assign a role carrying prvReadbot by hand." }
                Invoke-Dv "systemusers($($user.systemuserid))/systemuserroles_association/`$ref" -Method Post -Body @{ '@odata.id' = "$api/roles($($role[0].roleid))" } | Out-Null
                Write-Ok "  role   Environment Maker assigned - no existing role carried prvReadbot (had: $($userRoles.name -join ', '))"
            }

            # 2. Read access on the agent row.
            Invoke-Dv 'GrantAccess' -Method Post -Body @{
                Target          = $target
                PrincipalAccess = @{ Principal = @{ '@odata.id' = "systemusers($($user.systemuserid))" }; AccessMask = 'ReadAccess' }
            } | Out-Null
            Write-Ok '  share  ReadAccess granted on the agent'

            # 3. Policy, only if it would swallow the share.
            $fix = Get-SharePolicyFix -Policy ([int]$row.accesscontrolpolicy) -Groups $row.authorizedsecuritygroupids
            if ($fix.Warn) { Write-Warning $fix.Warn }
            if ($null -ne $fix.Set) {
                Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{ accesscontrolpolicy = $fix.Set } | Out-Null
                Write-Ok "  policy was 2 with no groups (nobody) - set to $($fix.Set) $($PolicyName[$fix.Set])"
            } else {
                Write-Info "  policy left at $($row.accesscontrolpolicy) $($PolicyName[[int]$row.accesscontrolpolicy])"
            }
        }

        # --- revoke one user --------------------------------------------------
        if ($RevokeUserEmail) {
            $user = Resolve-DvUser $RevokeUserEmail
            Write-Info "revoke: $($user.fullname) <$($user.domainname)>"

            # 1. Drop the row share, then prove it is gone.
            Invoke-Dv 'RevokeAccess' -Method Post -Body @{
                Target  = $target
                Revokee = @{ '@odata.id' = "systemusers($($user.systemuserid))" }
            } | Out-Null
            $still = Get-SharedPrincipals $target | Where-Object { $_.Principal.ownerid -eq $user.systemuserid }
            if ($still) { throw "RevokeAccess returned success but the share is still there: $($still.AccessMask)" }
            Write-Ok '  share  revoked on the agent'

            # 2. Policy, if it would make the revoke meaningless.
            $fix = Get-RevokePolicyFix -Policy ([int]$row.accesscontrolpolicy) -Groups $row.authorizedsecuritygroupids
            if ($fix.Warn) { Write-Warning $fix.Warn }
            if ($null -ne $fix.Set) {
                Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{ accesscontrolpolicy = $fix.Set } | Out-Null
                Write-Ok "  policy narrowed to $($fix.Set) $($PolicyName[$fix.Set])"
            } else {
                Write-Info "  policy left at $($row.accesscontrolpolicy) $($PolicyName[[int]$row.accesscontrolpolicy])"
            }

            # The environment role is deliberately left alone - it governs every
            # agent here, not this one.
            Write-Info '  role   left as is. Environment Maker governs the whole environment, not this agent.'
        }

        $after = Invoke-Dv "bots($($row.botid))?`$select=accesscontrolpolicy,authorizedsecuritygroupids"
        Write-Info "now: policy=$($after.accesscontrolpolicy) $($PolicyName[[int]$after.accesscontrolpolicy]) $($after.authorizedsecuritygroupids)"

        # --- publish ----------------------------------------------------------
        if ($NoPublish) {
            Write-Warning "NOT published (-NoPublish). Nothing above reaches the runtime until you run: pac copilot publish --environment $OrgUrl --bot $Bot"
            return
        }

        $pac = Resolve-Pac
        # Publish by the agent's GUID, not its schema name. --bot takes either,
        # but the id is already in hand and it skips a name lookup that has been
        # seen to crash pac with System.ArgumentException on a freshly imported
        # agent that has never been published. pac.cmd also does not propagate
        # exit codes, so the proof of a publish is publishedon moving.
        $pubOut = & $pac copilot publish --environment $OrgUrl --bot $row.botid 2>&1 | ForEach-Object { "$_" }
        $pubOut | ForEach-Object { Write-Info $_ }

        if ($pubOut -match 'non-recoverable error') {
            throw ("pac crashed while publishing $Bot. This is a fault in the CLI, not in the agent - the sharing " +
                   "changes above are already written. Its own log says why: " +
                   "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\<version>\tools\logs\pac-log.txt. " +
                   'Publish this agent from the Copilot Studio designer, or update pac and re-run.')
        }

        $publishedon = (Invoke-Dv "bots($($row.botid))?`$select=publishedon").publishedon
        if (-not $publishedon) {
            throw ("Not published: $Bot has never been published and still has no publish date. " +
                   "The sharing changes are already written. Check 'pac auth list' points at an identity " +
                   "that can publish in $OrgUrl, or publish once from the designer.")
        }
        if ($row.publishedon -and [datetime]$publishedon -le [datetime]$row.publishedon) {
            throw ("Not published: publishedon is still $($row.publishedon). Check the active profile with " +
                   "'pac auth list' - the sharing change itself is already written.")
        }
        Write-Ok "published at $publishedon"
    }

    # ==========================================================================
    # every agent, in order
    # ==========================================================================
    if ($modes.Count -eq 0) {
        Write-Info 'No grant given - reporting current access only, nothing will change.'
    }
    Write-Info "org      $OrgUrl"
    Write-Info "agents   $($Agent -join ', ')"

    $failed = @()
    $n = 0
    foreach ($bot in $Agent) {
        $n++
        Write-Stage "5.$n  $bot"
        try { Invoke-AgentStage -Bot $bot }
        catch {
            $failed += $bot
            Write-Host "    FAILED on $bot : $($_.Exception.Message)" -ForegroundColor Red
            if (-not $ContinueOnError) { throw }
        }
    }

    Save-State @{ OrgUrl = $OrgUrl; Agents = $Agent }

    if ($failed.Count) {
        Write-Stage 'Step 3 finished with failures'
        # throw, not exit: exit inside a function kills the whole script and the
        # orchestrator below never gets to name the stage that failed.
        throw "Failed on: $($failed -join ', ')"
    }

    Write-Stage 'Step 3 complete'
    if ($modes.Count -eq 0) {
        Write-Info 'Report only - nothing was changed. Re-run with -Everyone to grant org-wide access.'
    } elseif ($NoPublish) {
        Write-Info 'Sharing written but NOT published (-NoPublish). Nothing reaches the runtime until you publish.'
    } else {
        Write-Host @'
    Deployment complete: machine registered, agents bound, shared and published.

    End-to-end validation, by hand:
      1. Open Agent 1 in a FRESH chat session - an open conversation keeps
         working on the old configuration until it idles out after 30 minutes.
      2. Give it a task that hands off to Agent 2.
      3. Watch the machine under Power Automate -> Monitor -> Machines and
         confirm the Computer Use session starts on it.
'@ -ForegroundColor Green
    }
}
catch {
    Write-Host "`nSTEP 3 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
}


# ============================================================================
# orchestration
#
#   Works out which stages will run, collects every input those stages need,
#   and only then starts stage 1. Nothing below prompts mid-run: each stage's
#   own collection is a pass-through once the value is already set.
# ============================================================================
try {
    # --- which stages ---------------------------------------------------------
    # Start from a real array. A pipeline that yields nothing gives $null, and
    # $null += 'a' then += 'b' concatenates into ONE string whose .Count is 1, so
    # a guard built that way never fires.
    $only = @()
    if ($OnlyPrepare) { $only += 'Prepare' }
    if ($OnlyMachine) { $only += 'Machine' }
    if ($OnlyShare)   { $only += 'Share' }
    if ($only.Count -gt 1) { throw "Pass only one -Only* switch, got: $($only -join ', ')" }

    if ($only.Count -eq 1) {
        $runPrepare = $only -contains 'Prepare'
        $runMachine = $only -contains 'Machine'
        $runShare   = $only -contains 'Share'
    } else {
        $runPrepare = -not $SkipPrepare
        $runMachine = -not $SkipMachine
        $runShare   = -not $SkipShare
    }
    if (-not ($runPrepare -or $runMachine -or $runShare)) { throw 'Every stage is skipped - nothing to do.' }

    Write-Banner 'CUA hand-over deployment'
    Write-Info ('stages   ' + (@(
        "$(if ($runPrepare) { '1 solution' }        else { '1 (skipped)' })",
        "$(if ($runMachine) { '2 machine + CUA' }   else { '2 (skipped)' })",
        "$(if ($runShare)   { '3 share + publish' } else { '3 (skipped)' })"
    ) -join '  ->  '))
    Write-Info "agents   $Agent1SchemaName, $Agent2SchemaName  (built in, not prompted)"

    # --- collect every input, once -------------------------------------------
    Write-Banner 'Collecting inputs'

    $OrgUrl = (Read-RequiredValue 'Target Dataverse org URL (https://org....crm.dynamics.com)' (Get-Fallback $OrgUrl 'OrgUrl')).TrimEnd('/')
    if ($OrgUrl -notmatch '^https://[^/]+\.dynamics\.com$') {
        throw "Dataverse org URL should look like https://<org>.crm.dynamics.com, got: $OrgUrl"
    }

    if ($runMachine -or ($runPrepare -and -not $SkipCreateDataverse) -or $ResolveLibraryId) {
        $TenantId = Read-RequiredGuid 'Tenant id' (Get-Fallback $TenantId 'TenantId')
    }
    if ($runMachine) {
        $EnvironmentId = Read-RequiredGuid 'Power Platform environment GUID' (Get-Fallback $EnvironmentId 'EnvironmentId')
    } elseif (-not $EnvironmentId) {
        $EnvironmentId = $State.EnvironmentId
    }

    # Publish order: Agent 1 first, then Agent 2.
    if (-not $Agent -or $Agent.Count -eq 0) { $Agent = @($Agent1SchemaName, $Agent2SchemaName) }
    $Agent = @($Agent | ForEach-Object { $_ -split '[,\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    # --- stage 1 --------------------------------------------------------------
    if ($runPrepare) {
        if ($SolutionPath -and -not (Test-Path -LiteralPath $SolutionPath -PathType Leaf)) {
            throw "Not a file: $SolutionPath"
        }
        if (-not $SolutionUrl -and -not $SolutionPath) {
            $SolutionUrl = Read-RequiredValue 'Solution package https URL' (Get-Fallback $SolutionUrl 'SolutionUrl')
        }
        $SharePointUrl = (Read-RequiredValue 'SharePoint site URL (https://<tenant>.sharepoint.com/sites/<site>)' (Get-Fallback $SharePointUrl 'SharePointUrl')).TrimEnd('/')

        if (-not $SkipKeyVault) {
            $SubscriptionId        = Read-RequiredValue  'Azure subscription id'                                (Get-Fallback $SubscriptionId        'SubscriptionId')
            $ResourceGroupName     = Read-RequiredValue  'Resource group name'                                  (Get-Fallback $ResourceGroupName     'ResourceGroupName')
            $Location              = Read-RequiredValue  'Azure region (e.g. East US)'                          (Get-Fallback $Location              'Location')
            $KeyVaultName          = Read-RequiredValue  'Key Vault name (globally unique)'                     (Get-Fallback $KeyVaultName          'KeyVaultName')
            # The AllowedEnvironments tag is the ENVIRONMENT id, not the tenant id.
        $AllowedEnvironmentTag = Resolve-AllowedEnvironments -EnvironmentId $EnvironmentId -TenantId $TenantId `
                                    -Tag (Get-Fallback $AllowedEnvironmentTag 'AllowedEnvironmentTag')
        Write-Info "AllowedEnvironments tag: $AllowedEnvironmentTag"
            $FnoUsername           = Read-RequiredValue  'F&O username'                                         (Get-Fallback $FnoUsername           'FnoUsername')
            $FnoPassword           = Read-RequiredSecret 'F&O password'                                         $FnoPassword
        }
        # The environment variables point at the vault whether or not this run
        # created it, so the vault coordinates are needed either way.
        if (-not $SkipFno -and (-not $FnoUsernameSecretUri -or -not $FnoPasswordSecretUri)) {
            $SubscriptionId    = Read-RequiredValue 'Azure subscription id' (Get-Fallback $SubscriptionId    'SubscriptionId')
            $ResourceGroupName = Read-RequiredValue 'Resource group name'   (Get-Fallback $ResourceGroupName 'ResourceGroupName')
            $KeyVaultName      = Read-RequiredValue 'Key Vault name'        (Get-Fallback $KeyVaultName      'KeyVaultName')
        }

        if (-not $SkipCreateDataverse) {
            $DataverseAppId     = Read-RequiredGuid   'Dataverse connection app (client) id' (Get-Fallback $DataverseAppId 'DataverseAppId')
            if (-not $DataverseTenantId) { $DataverseTenantId = $TenantId }
            $DataverseAppSecret = Read-RequiredSecret 'Dataverse app client secret'          $DataverseAppSecret
        }
        if ($ResolveLibraryId) {
            $GraphClientId     = Read-RequiredGuid   'Graph app registration client id' (Get-Fallback $GraphClientId 'GraphClientId')
            $GraphClientSecret = Read-RequiredSecret 'Graph app client secret'          $GraphClientSecret
        }
    }

    # --- stage 2 --------------------------------------------------------------
    if ($runMachine) {
        if (-not $SkipRegistration) {
            $ApplicationId   = Read-RequiredGuid   'Machine-registration app (client) id'   (Get-Fallback $ApplicationId 'ApplicationId')
            $PadClientSecret = Read-RequiredSecret 'Machine-registration app client secret' $PadClientSecret
        }
        if (-not $ConnectionName) { $ConnectionName = Get-Fallback $ConnectionName 'ConnectionName' }
        if (-not $ConnectionName) { $ConnectionName = "$MachineName-CUA" }

        if (-not $SkipConnection) {
            $MachineUsername = Read-RequiredValue  "Windows username that signs in to $MachineName" (Get-Fallback $MachineUsername 'MachineUsername')
            $MachinePassword = Read-RequiredSecret 'Windows password'                               $MachinePassword
        }
        if (-not $SkipManualAuth) {
            $AuthClientId     = Read-RequiredGuid   'Agent authentication app (client) id'   (Get-Fallback $AuthClientId 'AuthClientId')
            $AuthClientSecret = Read-RequiredSecret 'Agent authentication app client secret' $AuthClientSecret
            if (-not $AuthTenantId)       { $AuthTenantId       = $TenantId }
            if (-not $SolutionUniqueName) { $SolutionUniqueName = $State.SolutionUniqueName }
        }
    }

    # --- stage 3 --------------------------------------------------------------
    $grants = @()
    if ($Everyone)        { $grants += '-Everyone' }
    if ($UserEmail)       { $grants += '-UserEmail' }
    if ($RevokeUserEmail) { $grants += '-RevokeUserEmail' }
    if ($RevokeEveryone)  { $grants += '-RevokeEveryone' }
    if ($ReportOnly)      { $grants += '-ReportOnly' }
    if ($grants.Count -gt 1) { throw "Pass only one grant at a time, got: $($grants -join ', ')" }
    # The flow's step 5 is an org-wide share, so that is the default when the
    # sharing stage runs and nothing else was asked for.
    if ($runShare -and $grants.Count -eq 0) {
        $Everyone = $true
        Write-Info 'No grant given - defaulting to -Everyone (org-wide share). Pass -ReportOnly to change nothing.'
    }

    # --- summary --------------------------------------------------------------
    Write-Banner 'Ready'
    Write-Info "org          $OrgUrl"
    if ($EnvironmentId) { Write-Info "environment  $EnvironmentId" }
    if ($runPrepare) {
        Write-Info "solution     $(if ($SolutionUrl) { $SolutionUrl } else { $SolutionPath })"
        Write-Info "sharepoint   $SharePointUrl"
        Write-Info "key vault    $(if ($SkipKeyVault) { "$KeyVaultName (reused)" } else { $KeyVaultName })"
    }
    if ($runMachine) {
        Write-Info "machine      $MachineName  ->  connection '$ConnectionName'"
        Write-Info "manual auth  $(if ($SkipManualAuth) { 'skipped' } else { "app $AuthClientId" })"
    }
    if ($runShare) {
        Write-Info "publish      $($Agent -join ', ')"
        Write-Info "grant        $(if ($ReportOnly) { 'report only, nothing changes' } elseif ($UserEmail) { $UserEmail } elseif ($RevokeUserEmail) { "revoke $RevokeUserEmail" } elseif ($RevokeEveryone) { 'revoke org-wide' } else { 'everyone in the organisation' })"
    }
    Write-Info 'secrets      held as SecureString, never written to disk'

    if ($WhatIfStages) {
        Write-Banner 'WhatIfStages - stopping without running anything'
        return
    }

    # --- run ------------------------------------------------------------------
    $stage = $null
    try {
        if ($runPrepare) {
            $stage = '1 solution preparation'
            Write-Banner 'Stage 1 of 3 - solution preparation'
            # The prepare stage calls the Graph app id/secret $ClientId and
            # $ClientSecret; the machine stage uses those same two names for the
            # PAD registration app. Alias them per stage so each body reads the
            # one it means.
            $ClientId     = $GraphClientId
            $ClientSecret = $GraphClientSecret
            Invoke-PrepareStage
        }

        if ($runMachine) {
            $stage = '2 machine and CUA configuration'
            Write-Banner 'Stage 2 of 3 - machine and CUA configuration'
            $ClientSecret = $PadClientSecret
            Invoke-MachineStage
        }

        if ($runShare) {
            $stage = '3 share and publish'
            Write-Banner 'Stage 3 of 3 - share and publish'
            Invoke-ShareStage
        }
    }
    catch {
        Write-Host ''
        Write-Host ('=' * 72) -ForegroundColor Red
        Write-Host "  STAGE $stage FAILED" -ForegroundColor Red
        Write-Host ('=' * 72) -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        $resume = switch -Wildcard ($stage) {
            '1*' { '.\Run-HandOver.ps1 -OnlyPrepare' }
            '2*' { '.\Run-HandOver.ps1 -SkipPrepare' }
            '3*' { '.\Run-HandOver.ps1 -OnlyShare' }
            default { '.\Run-HandOver.ps1' }
        }
        Write-Host '  Later stages were NOT run. Fix the cause, then resume with:' -ForegroundColor Yellow
        Write-Host "      $resume" -ForegroundColor Yellow
        Write-Host '  Answers already given are cached in handover-state.json, so you will not be asked again.' -ForegroundColor Yellow
        Write-Host ''
        throw
    }

    Write-Banner 'Hand-over complete'
    Write-Info 'All requested stages finished.'
}
catch {
    exit 1
}
