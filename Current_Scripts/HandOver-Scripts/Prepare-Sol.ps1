<#
.SYNOPSIS
  Hand-over step 1, standalone: prepare the solution package and import it into
  the target Power Platform environment. Flow step 1.

.DESCRIPTION
  Self-contained. It calls no other script in this repo.

      1.1  download the solution package from an https URL
      1.2  create the Azure Key Vault, assign RBAC to the current user, to
           Copilot Studio and to Dataverse, and store the F&O credentials as
           secrets tagged for this environment
      1.3  unpack, retarget the SharePoint site and Dataverse org across the
           flow and both agent tools, point the FnoUsername / FnoPassword
           environment variables at the vault secrets, repack
      1.4  create the Dataverse and SharePoint connections, fill in the
           deployment settings file, and import with it

  GATE: the import must succeed before Machine-and-Cua.ps1. On success the
  solutions in the environment are listed so you can see yours landed.

  ORDER. The Key Vault is created before the connections. The pack step sits
  between them because the connection references are read out of a PACKED
  solution, so the retargeted zip has to exist first. The import carries
  --settings-file, without which the imported agent arrives with empty
  connection references and its tools fail at run time.

  NOTHING IS SHARED OR PUBLISHED HERE. That is Share-Agents.ps1, after the
  machine and the agent binding exist.

  ENCODING. Every file rewritten between unpack and pack is written as UTF-8
  WITHOUT a BOM, through .NET rather than Set-Content. Windows PowerShell 5.1
  has no 'utf8NoBOM' encoding name, and its -Encoding utf8 means UTF-8 WITH a
  BOM - which makes the import fail with "Flow clientdata is in invalid format".

  AUTHENTICATION. `az login` for the Key Vault and the connections; a `pac auth`
  profile for unpack, pack and import; and, only with -ResolveLibraryId, an
  app-only Graph token from -ClientId / -TenantId / -ClientSecret.

  The first SharePoint connection in a new environment needs a person to sign in
  once - shared_sharepointonline publishes no service principal parameter set,
  so this is a platform limit rather than a gap here. After that its id is
  reusable: pass -SkipCreateSharePoint with a -Connection pin.

.PARAMETER SolutionUrl
  https URL serving the solution zip. Prompted for if neither this nor
  -SolutionPath is given.

.PARAMETER SolutionPath
  Local solution zip, as an alternative to -SolutionUrl.

.PARAMETER OrgUrl
  Target Dataverse org URL, e.g. https://org35fd7a12.crm.dynamics.com

.PARAMETER EnvironmentId
  Power Platform environment GUID. Looked up from -OrgUrl when omitted.

.PARAMETER SharePointUrl
  SharePoint site the solution's flow and file tool should point at, e.g.
  https://contoso.sharepoint.com/sites/AICOE

.PARAMETER SubscriptionId
  Azure subscription holding the Key Vault.

.PARAMETER ResourceGroupName
  Resource group for the Key Vault. Created if missing.

.PARAMETER Location
  Azure region for the resource group and vault, e.g. 'East US'.

.PARAMETER KeyVaultName
  Key Vault name. Must be globally unique. Created if missing; an existing vault
  is reused only when it already uses Azure RBAC - the permission model is never
  changed automatically.

.PARAMETER AllowedEnvironmentTag
  Value for the AllowedEnvironments tag stamped on both secrets. Power Platform
  reads this tag to decide which ENVIRONMENTS may resolve the secret, so it is a
  comma-separated list of environment ids - NOT the tenant id. Defaults to
  -EnvironmentId, which is what you want unless more than one environment should
  read the same secret. Passing the tenant id here is rejected: it produces a
  vault that looks correct and then fails to resolve at run time.

.PARAMETER UsernameSecretName
  Key Vault secret name holding the F&O username. Default 'FnoUsername'.

.PARAMETER PasswordSecretName
  Key Vault secret name holding the F&O password. Default 'FnoPassword'.

.PARAMETER FnoUsername
  F&O username to store in the vault. Prompted for if omitted.

.PARAMETER FnoPassword
  F&O password, as a SecureString. Prompted for with -AsSecureString if omitted.
  Written to the vault through a temp file that is deleted immediately, never
  placed on a command line.

.PARAMETER FnoUsernameSecretUri
  Key Vault secret reference the solution's FnoUsername environment variable is
  pointed at. Built from the vault parameters when omitted.

.PARAMETER FnoPasswordSecretUri
  Same for FnoPassword.

.PARAMETER DataverseAppId
  Client id of the app registration the new Dataverse connection signs in as.
  That app must already be an application user in the target environment.

.PARAMETER DataverseTenantId
  Tenant of that app registration.

.PARAMETER DataverseAppSecret
  Its client secret, as a SecureString.

.PARAMETER Connection
  Pins a connector to an existing connection id, 'connector=id', comma
  separated. Use it where more than one connection would match and the run must
  stay unattended.

.PARAMETER Mode
  'literal' writes the site and org straight into the flow and tools.
  'envvar' declares environment variables and points everything at those.

.PARAMETER SharePointSiteVariable
.PARAMETER DataverseOrgVariable
.PARAMETER SharePointLibraryVariable
  Schema names of the environment variables used in 'envvar' mode. These are
  properties of the solution package, not of an environment.

.PARAMETER CsvFlowPattern
.PARAMETER SharePointToolPattern
.PARAMETER DataverseToolPattern
  Which files inside the unpacked solution carry the values to retarget. Change
  these only if the solution's flow or agent tools are renamed.

.PARAMETER ResolveLibraryId
  Look the SharePoint document library id up on the target site via Graph, and
  write it into the flow. Needs -ClientId / -TenantId / -ClientSecret.

.PARAMETER SkipKeyVault
  Skip 1.2. The vault and both secrets must already exist, because the
  environment variables are still pointed at them.

.PARAMETER SkipCreateDataverse
  Bind to an existing Dataverse connection instead of creating one.

.PARAMETER SkipCreateSharePoint
  Bind to an existing SharePoint connection instead of creating one.

.PARAMETER SkipImport
  Stop after writing the deployment settings file. Nothing in the environment is
  touched and the gate check is skipped.

.PARAMETER KeepSource
  Keep the unpacked solution at this path instead of a temp folder, for
  inspecting what was rewritten.

.PARAMETER SelfTest
  Run the pure helpers against their known cases and exit. Needs no tenant.

.EXAMPLE
  .\Prepare-Sol.ps1 -SolutionUrl https://files.catbox.moe/abc123.zip `
                    -OrgUrl https://org35fd7a12.crm.dynamics.com `
                    -SharePointUrl https://contoso.sharepoint.com/sites/AICOE `
                    -SubscriptionId 0c33fa37-4fa1-466d-a891-46af9e2f6e44 `
                    -ResourceGroupName rg-cua-uat -Location 'East US' `
                    -KeyVaultName kv-cua-uat-01 `
                    -EnvironmentId 20bbbb76-91c1-efde-bf32-8a5468336104 `
                    -DataverseAppId <app-guid> -DataverseTenantId <tenant-guid>

.EXAMPLE
  .\Prepare-Sol.ps1 -SolutionPath .\CUAExecutionValidator.zip -SkipKeyVault -SkipImport

  Dry run: retarget and pack against an existing vault, write the settings file,
  touch nothing in the environment.

.EXAMPLE
  .\Prepare-Sol.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [switch] $Help,

    [string] $SolutionUrl,
    [string] $SolutionPath,
    [string] $OutFile,
    [string] $KeepSource,

    [string] $OrgUrl,
    [string] $EnvironmentId,
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
    [string] $ClientId,
    [string] $TenantId,
    [securestring] $ClientSecret,

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
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Write-Stage { param([string] $m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Info  { param([string] $m) Write-Host "    $m" }
function Write-Ok    { param([string] $m) Write-Host "    $m" -ForegroundColor Green }
function Write-Gate  { param([string] $m) Write-Host "    GATE  $m" -ForegroundColor Green }


$SecretRefPattern = '(?i)^/subscriptions/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/resourcegroups/(.+?)/providers/Microsoft\.KeyVault/(.+?)/secrets/(.+)$'
$SecretRefHint    = 'Valid format: /subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>/secrets/<secret>'

function ConvertFrom-PacConnectionList {
    <# `pac connection list` prints a fixed-width table; names contain spaces. #>
    param([string[]] $Lines)
    $out = @()
    foreach ($line in $Lines) {
        $t = ($line -split '\s+') | Where-Object { $_ }
        if ($t.Count -lt 4) { continue }
        if ($t[-2] -notmatch '^/providers/Microsoft\.PowerApps/apis/') { continue }
        $out += [pscustomobject]@{
            Id        = $t[0]
            Connector = $t[-2] -replace '^.*/', ''
            Status    = $t[-1]
            Name      = ($t[1..($t.Count - 3)] -join ' ')
        }
    }
    $out
}

function Split-DeferredReferences {
    <#
      Some connection references cannot be bound at import time, because the
      connection they point at does not exist yet.

      shared_computeroperator is the one this pipeline hits. The Computer Use
      connection is created in step 3.3, which needs a REGISTERED MACHINE,
      which needs step 2, which runs AFTER this import. Requiring it here is a
      chicken-and-egg no fresh environment can satisfy, and the error it produced
      told you to create a connection that cannot exist yet.

      Dropping the entry is the fix, not blanking it - the same trap as the
      environment variables: pac rejects an empty value in this file, while an
      absent entry imports cleanly and leaves the reference unbound. Step 2
      sub-steps 4.1-4.3 then create the reference, link it and repoint the
      action, which is where that binding belongs.

      SettingsObject is mutated: the deferred entries are removed from it, so the
      file written afterwards does not mention them.
    #>
    param($SettingsObject, [string[]] $DeferConnector)

    $refs     = @($SettingsObject.ConnectionReferences)
    $deferred = @($refs | Where-Object { ($_.ConnectorId -replace '^.*/', '') -in    $DeferConnector })
    $bind     = @($refs | Where-Object { ($_.ConnectorId -replace '^.*/', '') -notin $DeferConnector })

    if ($deferred.Count) { $SettingsObject.ConnectionReferences = $bind }
    @{ Bind = $bind; Deferred = $deferred }
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

    if ($EnvironmentId -and $ids -notcontains $EnvironmentId) {
        throw @"
The AllowedEnvironments tag ($($ids -join ',')) does not list the environment
being deployed to ($EnvironmentId), so that environment could not resolve the
secret at run time.

A stale value cached in handover-state.json is the usual cause: the tag is saved
there by an earlier run against a different environment, and the cached value
wins over an -EnvironmentId passed on the command line. Delete the
AllowedEnvironmentTag entry from that file, or pass -AllowedEnvironmentTag with
a list that includes $EnvironmentId.
"@
    }

    $ids -join ','
}

if ($SelfTest) {
    $rows = ConvertFrom-PacConnectionList @(
        'Id                        Name             API Id                                                       Status',
        'shared-sharepointonl-25   Demouser1@x.com  /providers/Microsoft.PowerApps/apis/shared_sharepointonline  Connected',
        '69f5e3e5258143            T14-GEN1 CUA     /providers/Microsoft.PowerApps/apis/shared_computeroperator  Connected',
        'Connected as somebody@example.com'
    )
    if ($rows.Count -ne 2)                               { throw "selftest: expected 2 rows, got $($rows.Count)" }
    if ($rows[0].Connector -ne 'shared_sharepointonline') { throw "selftest: connector was '$($rows[0].Connector)'" }
    if ($rows[1].Name      -ne 'T14-GEN1 CUA')            { throw "selftest: a name with a space was cut to '$($rows[1].Name)'" }
    if ($rows[0].Id        -ne 'shared-sharepointonl-25') { throw "selftest: id was '$($rows[0].Id)'" }

    $ref = New-SecretReference -Subscription '0c33fa37-4fa1-466d-a891-46af9e2f6e44' `
                               -ResourceGroup 'rg' -Vault 'kv' -Secret 'FnoUsername'
    if ($ref -notmatch $SecretRefPattern) { throw "selftest: a built reference must be valid, got $ref" }
    foreach ($bad in 'not-a-ref',
                     '/subscriptions/nope/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv/secrets/s',
                     "$ref`ntrailing") {
        if ($bad -match $SecretRefPattern) { throw "selftest: secret pattern wrongly accepted '$bad'" }
    }
    'ok'; return
}

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

    $caller = Get-AzCallerIdentity
    Write-Info "caller $($caller.What) [$($caller.Type)]"

    $assignments = @(
        @{ Id = $caller.Id; Type = $caller.Type; Role = 'Key Vault Secrets Officer'; What = "$($caller.What) (to write the secrets)" }
        @{ Id = $caller.Id; Type = $caller.Type; Role = 'Key Vault Secrets User';    What = "$($caller.What) (to read them back)" }
    )

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
        if ($inInputs -and $lines[$i] -match '^\S') { break }
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

        $script:PackagedBots = @(Get-ChildItem -LiteralPath (Join-Path $work 'bots') -Directory |
                                 Select-Object -ExpandProperty Name)
        Write-Info "agents in package: $($script:PackagedBots -join ', ')"

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
            if ($inputs -is [string] -or $null -eq $inputs) { continue }
            if ($inputs.PSObject.Properties.Name -notcontains 'parameters') { continue }
            $p     = $inputs.parameters
            $names = $p.PSObject.Properties.Name

            if (-not $folderHint -and $names -contains 'folderPath' -and
                $p.folderPath -is [string] -and $p.folderPath.StartsWith('/')) {
                $folderHint = $p.folderPath
            }
            if ($names -contains 'table') { $tableParams += $p }

            if ($names -notcontains 'dataset') { continue }
            $cur = $p.dataset
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

        if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
        & $pac solution pack --zipfile $Out --folder $work --packagetype $PackType
        if ($LASTEXITCODE -ne 0) { throw "pac solution pack failed (exit $LASTEXITCODE)" }
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
        [bool] $DoImport,
        [string[]] $DeferConnector  = @('shared_computeroperator'),
        [string[]] $ConsentConnector = @('shared_microsoftcopilotstudio')
    )

    $pac = Resolve-Pac

    if (Test-Path -LiteralPath $Settings) { Remove-Item -LiteralPath $Settings -Force }
    & $pac solution create-settings --solution-zip $Zip --settings-file $Settings 2>&1 | ForEach-Object { Write-Info $_ }
    if (-not (Test-Path -LiteralPath $Settings)) {
        throw "pac solution create-settings reported success but $Settings is not there."
    }

    $settingsObj = Get-Content -LiteralPath $Settings -Raw | ConvertFrom-Json
    $refs = @($settingsObj.ConnectionReferences)
    if (-not $refs) { throw 'The solution declares no connection references - nothing to bind.' }
    Write-Info "$($refs.Count) connection reference(s) in the solution."

    $vars  = @($settingsObj.EnvironmentVariables)
    $empty = @($vars | Where-Object { -not $_.Value })
    if ($empty) {
        $settingsObj.EnvironmentVariables = @($vars | Where-Object { $_.Value })
        Write-Info ("dropped $($empty.Count) environment variable(s) with no value, keeping the solution's own: " +
                    ($empty.SchemaName -join ', '))
    }

    <#
      Some connection references cannot be bound at import time because the
      connection they point at does not exist yet.

      shared_computeroperator is the one: the Computer Use connection is created
      in stage 3.3, which needs a REGISTERED MACHINE, which needs stage 2, which
      runs after this import. Demanding it here is a chicken-and-egg - the import
      can never succeed on a fresh environment.

      Dropping the entry is the right move, not blanking it: pac rejects an empty
      value in this file, while an absent entry imports cleanly and leaves the
      reference unbound. Stage 2 steps 4.1-4.3 then create the reference, link it
      and repoint the action, which is where that binding belongs anyway.
    #>
    $split = Split-DeferredReferences -SettingsObject $settingsObj -DeferConnector $DeferConnector
    $refs  = @($split.Bind)
    if ($split.Deferred.Count) {
        Write-Info ("deferred $($split.Deferred.Count) connection reference(s) to step 2, left unbound by the import: " +
                    (@($split.Deferred | ForEach-Object { $_.LogicalName }) -join ', '))
    }

    $paHeaders = $null
    $envFilter = $null
    if ($DoDataverse -or $DoSharePoint) {
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is needed to create a connection.' }
        if (-not (az account show 2>$null)) { throw 'No Azure CLI session. Run: az login' }

        $paToken = az account get-access-token --resource 'https://service.powerapps.com/' --query accessToken -o tsv
        if (-not $paToken) { throw 'Could not get a Power Apps token.' }
        $paHeaders = @{ Authorization = "Bearer $paToken"; Accept = 'application/json' }

        if (-not $EnvId) {
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

        $envFilter = '&%24filter=' + [uri]::EscapeDataString("environment eq '$EnvId'")
    }

    if ($DoDataverse) {
        Write-Info 'Creating a Dataverse connection (service principal)...'
        if (-not $AppId)     { throw 'Creating the Dataverse connection needs -DataverseAppId.' }
        if (-not $Tenant)    { throw 'Creating the Dataverse connection needs -DataverseTenantId.' }
        if (-not $AppSecret) { throw 'Creating the Dataverse connection needs -DataverseAppSecret.' }

        $newId = (New-Guid).Guid.Replace('-', '')
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

        $made   = Invoke-RestMethod -Uri $url -Headers $paHeaders
        $status = $made.properties.statuses | Select-Object -First 1
        if ($status.status -ne 'Connected') {
            throw "Connection $newId was created but is '$($status.status)': $($status.error.message). Check the secret, and that $AppId is an application user in this environment."
        }
        Write-Ok "created $newId ($DataverseName) Connected"
        $Pins['shared_commondataserviceforapps'] = $newId
    }

    function New-ConsentedConnection {
        <#
          Some connectors publish no service principal parameter set at all, so
          the connection has to be consented to by a person. shared_sharepointonline
          is one; shared_microsoftcopilotstudio is another, and it is NOT created
          by any later step, so unlike shared_computeroperator it cannot simply
          be deferred - without it the agent-to-agent action has nothing to call.

          What can be automated is everything around the sign-in: the shell, the
          consent link and the polling. The human part is one sign-in, usually one
          click.

          Reads $paHeaders, $envFilter, $EnvId and $ConsentTimeout from the
          enclosing function. Returns the new connection id.
        #>
        param(
            [Parameter(Mandatory)][string] $Connector,
            [Parameter(Mandatory)][string] $Name,
            [string] $IdPrefix
        )

        Assert-AzUserSession "Creating the first '$Connector' connection in an environment"
        $newId = if ($IdPrefix) { $IdPrefix + [Guid]::NewGuid().ToString() }
                 else           { (New-Guid).Guid.Replace('-', '') }
        $url = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/' +
               "$Connector/connections/${newId}?api-version=2016-11-01" + $envFilter

        $body = @{ properties = @{
            displayName          = $Name
            environment          = @{ id = "/providers/Microsoft.PowerApps/environments/$EnvId"; name = $EnvId }
            connectionParameters = @{}
        } } | ConvertTo-Json -Depth 10

        Invoke-RestMethod -Method Put -Uri $url -Headers $paHeaders -ContentType 'application/json' -Body $body | Out-Null
        Write-Info "created $newId unauthenticated, asking for a consent link"

        <#
          Signing in at the consent link is what authenticates the connection;
          the portal's follow-up confirmConsentCode call is bookkeeping, not a
          requirement. So there is nothing to catch - ask the service, and poll.
        #>
        $redirect = 'https://make.powerapps.com/connection/oauth/redirect?oauthPopupId=' + [Guid]::NewGuid()
        $linkUrl  = 'https://api.powerapps.com/providers/Microsoft.PowerApps/apis/' +
                    "$Connector/connections/$newId/getConsentLink?api-version=2016-11-01" + $envFilter
        $link = (Invoke-RestMethod -Method Post -Uri $linkUrl -Headers $paHeaders -ContentType 'application/json' `
                    -Body (@{ redirectUrl = $redirect } | ConvertTo-Json)).consentLink
        if (-not $link) { throw "The consent service returned no link for $Connector." }

        Write-Host ''
        Write-Host "    A browser window is opening for '$Connector'. Sign in as the account the agent should run as." -ForegroundColor Yellow
        Write-Host "    If it does not open, paste this in yourself:`n    $link"
        Start-Process $link

        $deadline = (Get-Date).AddSeconds($ConsentTimeout)
        do {
            Start-Sleep -Seconds 3
            $status = (Invoke-RestMethod -Uri $url -Headers $paHeaders).properties.statuses | Select-Object -First 1
            Write-Info "waiting for sign-in... $($status.status)"
        } while ($status.status -ne 'Connected' -and (Get-Date) -lt $deadline)

        if ($status.status -ne 'Connected') {
            throw ("Still '$($status.status)' after $ConsentTimeout seconds. " +
                   "Connection $newId is left behind - delete it in make.powerapps.com, or sign it in there " +
                   "and re-run with -Connection $Connector=$newId.")
        }

        $made = Invoke-RestMethod -Uri $url -Headers $paHeaders
        Write-Ok "created $newId ($($made.properties.displayName)) Connected as $($made.properties.authenticatedUser.name)"
        $newId
    }

    if ($DoSharePoint) {
        Write-Info 'Creating a SharePoint connection...'
        $Pins['shared_sharepointonline'] = New-ConsentedConnection -Connector 'shared_sharepointonline' `
            -Name $SharePointName -IdPrefix 'shared-sharepointonl-'
    }

    $listed = & $pac connection list --environment $EnvironmentUrl 2>&1 | ForEach-Object { "$_" }
    $conns  = @(ConvertFrom-PacConnectionList $listed)
    if (-not $conns) {
        $listed | ForEach-Object { Write-Info $_ }
        throw "No connections were listed. Check 'pac auth list' points at $EnvironmentUrl."
    }
    $conns | Group-Object Connector | ForEach-Object { Write-Info "$($_.Name): $($_.Count) connection(s)" }

    foreach ($r in $refs) {
        $connector = $r.ConnectorId -replace '^.*/', ''

        if ($Pins.ContainsKey($connector)) {
            $r.ConnectionId = $Pins[$connector]
            Write-Info "$connector -> $($r.ConnectionId)  (pinned)"
            continue
        }

        $candidates = @($conns | Where-Object { $_.Connector -eq $connector -and $_.Status -eq 'Connected' })

        <#
          A connector that only a person can authenticate, with nothing in the
          environment yet. Creating it here rather than throwing is the whole
          point: this is exactly the moment we know it is needed and know it is
          missing. SharePoint is deliberately NOT in this list - it has its own
          -SkipCreateSharePoint switch, and honouring that matters more.
        #>
        if ($candidates.Count -eq 0 -and $connector -in $ConsentConnector) {
            Write-Info "$connector has no connection here, and only a person can create one."
            $r.ConnectionId  = New-ConsentedConnection -Connector $connector `
                                   -Name (($connector -replace '^shared_', '') + '-oauth')
            $Pins[$connector] = $r.ConnectionId
            Write-Info "$connector -> $($r.ConnectionId)  (consented just now)"
            continue
        }

        if ($candidates.Count -eq 0) {
            throw @"
No connected '$connector' connection exists in $EnvironmentUrl.

Create one first - these connectors sign in as a user, so the first one needs a
human to consent:

    Dataverse    re-run without -SkipCreateDataverse
    SharePoint   re-run without -SkipCreateSharePoint, or create one at
                 make.powerapps.com -> Connections -> New connection

then run this again.

If this connector's connection is created by a LATER step - as
shared_computeroperator is, in step 3.3 - it cannot exist yet and does not
belong here at all. Add it to Split-DeferredReferences' -DeferConnector list so
the import leaves the reference unbound.
"@
        }

        if ($candidates.Count -eq 1) {
            $r.ConnectionId = $candidates[0].Id
            Write-Info "$connector -> $($r.ConnectionId)"
            continue
        }

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

    [System.IO.File]::WriteAllText($Settings, ($settingsObj | ConvertTo-Json -Depth 20),
                                   (New-Object System.Text.UTF8Encoding $false))
    Write-Ok "wrote $Settings"

    if (-not $DoImport) {
        Write-Info "Import skipped. Import with:  pac solution import --environment $EnvironmentUrl --path $Zip --settings-file $Settings"
        return
    }

    $out = & $pac solution import --environment $EnvironmentUrl --path $Zip `
                --settings-file $Settings --publish-changes --force-overwrite `
                --activate-plugins --max-async-wait-time 60 2>&1 | ForEach-Object { "$_" }
    $out | ForEach-Object { Write-Info $_ }
    if ($LASTEXITCODE -ne 0 -or ($out -match '^\s*Error:')) {
        $why = @($out | Where-Object { $_ -match '(?i)error|fail|unable|cannot|missing' }) -join "`n  "
        throw ("Import failed.`n  " + $why +
               "`n`nThe settings file is at $Settings - it is reusable, fix the cause and re-run.")
    }
    Write-Ok 'import succeeded.'
}

try {
    Write-Stage 'Step 1 - Solution preparation'

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
        if (-not $AllowedEnvironmentTag -and -not (Get-Fallback $AllowedEnvironmentTag 'AllowedEnvironmentTag') -and -not $EnvironmentId) {
            $EnvironmentId = Read-RequiredValue 'Power Platform environment GUID (for the AllowedEnvironments secret tag)' (Get-Fallback $EnvironmentId 'EnvironmentId')
        }
        $AllowedEnvironmentTag = Resolve-AllowedEnvironments -EnvironmentId $EnvironmentId -TenantId $DataverseTenantId `
                                    -Tag (Get-Fallback $AllowedEnvironmentTag 'AllowedEnvironmentTag')
        Write-Info "AllowedEnvironments tag: $AllowedEnvironmentTag"
        $FnoUsername           = Read-RequiredValue  'F&O username'                                         (Get-Fallback $FnoUsername           'FnoUsername')
        $FnoPassword           = Read-RequiredSecret 'F&O password'                                         $FnoPassword
    }

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

    Write-Stage 'Gate - import succeeded'
    if ($SkipImport) {
        Write-Host '    Import skipped (-SkipImport). Settings file written, environment untouched.' -ForegroundColor Yellow
    } else {
        $pac = Resolve-Pac
        & $pac solution list --environment $OrgUrl 2>&1 | ForEach-Object { Write-Info $_ }
        Write-Gate 'Confirm your solution is listed above before running Machine-and-Cua.ps1.'
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
    Write-Info 'Next: .\Machine-and-Cua.ps1   (run as Administrator, on the VM itself)'
}
catch {
    Write-Host "`nSTEP 1 FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
