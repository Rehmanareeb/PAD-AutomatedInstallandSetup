<#
.SYNOPSIS
  Orchestrator: runs the whole hand-over deployment in order - solution
  preparation, machine and CUA configuration, then sharing and publishing.

.DESCRIPTION
  One point of control over the three stage scripts:

      1  Prepare-Sol.ps1       flow step 1 - Key Vault, connections, import
      2  Machine-and-Cua.ps1   flow steps 3 and 4 - machine, connection, binding
      3  Share-Agents.ps1      flow step 5 - share and publish

  Flow step 2, provisioning the VM itself, happens before any of this and is not
  scripted here - these run inside the VM that step produced.

  EVERY INPUT IS COLLECTED UP FRONT. The stages that will actually run are worked
  out first, then anything missing for those stages is prompted for, and only
  then does stage 1 start. Nothing stops halfway through to ask a question. All
  values are passed down as explicit parameters, so no stage script prompts
  either. Secrets are read with -AsSecureString and never written to disk.

  STOPS ON THE FIRST FAILURE and names the stage that failed, with the command to
  resume from that point. Stage 2 must not run against a failed import, and stage
  3 must not publish an agent whose Computer Use binding never landed.

  Every stage script also runs standalone - the orchestrator is a convenience,
  not a requirement.

.PARAMETER SkipPrepare
  Do not run Prepare-Sol.ps1.

.PARAMETER SkipMachine
  Do not run Machine-and-Cua.ps1.

.PARAMETER SkipShare
  Do not run Share-Agents.ps1.

.PARAMETER OnlyPrepare
  Run stage 1 alone.

.PARAMETER OnlyMachine
  Run stage 2 alone.

.PARAMETER OnlyShare
  Run stage 3 alone.

.PARAMETER WhatIfStages
  Print the stages that would run and every value collected, then stop without
  touching anything. Use it to check a long command line before committing.

.PARAMETER SourceRoot
  Folder holding the original scripts. Defaults to this script's parent, i.e.
  Current_Scripts.

.PARAMETER OrgUrl
  Target Dataverse org URL, e.g. https://org35fd7a12.crm.dynamics.com

.PARAMETER EnvironmentId
  Power Platform environment GUID.

.PARAMETER TenantId
  Directory (tenant) id.

.PARAMETER SolutionUrl
  https URL serving the solution zip. Stage 1.

.PARAMETER SolutionPath
  Local solution zip, as an alternative to -SolutionUrl. Stage 1.

.PARAMETER SharePointUrl
  SharePoint site the solution's flows should point at. Stage 1.

.PARAMETER SubscriptionId
  Azure subscription holding the Key Vault. Stage 1.

.PARAMETER ResourceGroupName
  Resource group for the Key Vault, created if missing. Stage 1.

.PARAMETER Location
  Azure region, e.g. 'East US'. Stage 1.

.PARAMETER KeyVaultName
  Key Vault name, globally unique. Stage 1.

.PARAMETER AllowedEnvironmentTag
  AllowedEnvironments tag stamped on both secrets, '<tenantId>,<environmentId>'.
  Stage 1.

.PARAMETER FnoUsername
  F&O username stored in the vault. Stage 1.

.PARAMETER FnoPassword
  F&O password, SecureString. Stage 1.

.PARAMETER DataverseAppId
  App registration the new Dataverse connection signs in as. Stage 1.

.PARAMETER DataverseAppSecret
  Its client secret, SecureString. Stage 1.

.PARAMETER ApplicationId
  App registration used for silent machine registration. Stage 2.

.PARAMETER PadClientSecret
  Its client secret, SecureString. Stage 2.

.PARAMETER MachineName
  Name this machine registers under. Defaults to $env:COMPUTERNAME. Stage 2.

.PARAMETER MachineUsername
  Windows account that signs in to the machine. Stage 2.

.PARAMETER MachinePassword
  That account's password, SecureString. Stage 2.

.PARAMETER Agent
  Schema names of the agents, in publish order. Stage 3, and the first entry is
  taken as Agent 1. Schema names, not display names.

.PARAMETER Agent2SchemaName
  Schema name of the Computer Use agent. Defaults to the last entry of -Agent.
  Stage 2.

.PARAMETER Agent2CuaComponentSchema
  Schema name of Agent 2's Computer Use action. Stage 2.

.PARAMETER Agent2DisplayName
  Agent 2's display name in Copilot Studio. Stage 2, manual authentication.

.PARAMETER AuthClientId
  Entra app Agent 2 authenticates its users with. Stage 2.

.PARAMETER AuthClientSecret
  Its client secret, SecureString. Stage 2.

.PARAMETER Everyone
  Share both agents with the organisation. Stage 3. This is the default grant
  when no other is given; pass -ReportOnly to change nothing.

.PARAMETER UserEmail
  Share with one user instead. Stage 3.

.PARAMETER ReportOnly
  Stage 3 reports current access and changes nothing.

.EXAMPLE
  .\Run-HandOver.ps1 -OrgUrl https://org35fd7a12.crm.dynamics.com `
                     -EnvironmentId 20bbbb76-91c1-efde-bf32-8a5468336104 `
                     -TenantId edda99bb-bab6-4c4c-8aa1-4b99e8e09c1b `
                     -SolutionUrl https://files.catbox.moe/abc123.zip `
                     -SharePointUrl https://contoso.sharepoint.com/sites/AICOE `
                     -SubscriptionId 0c33fa37-4fa1-466d-a891-46af9e2f6e44 `
                     -ResourceGroupName rg-cua-uat -Location 'East US' `
                     -KeyVaultName kv-cua-uat-01 `
                     -Agent cr720_Agent1TestScript,cr720_Agent2UITesting `
                     -Everyone

  Full deployment. Prompts once, up front, for anything still missing.

.EXAMPLE
  .\Run-HandOver.ps1 -OnlyShare -Everyone

  The first two stages already ran - just share and publish.

.EXAMPLE
  .\Run-HandOver.ps1 -SkipPrepare -WhatIfStages

  Show which stages would run and what values they would get, without doing
  anything.

.EXAMPLE
  .\Run-HandOver.ps1 -Help
#>
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

    [ValidateNotNullOrEmpty()]
    [string] $SourceRoot = (Split-Path -Parent $PSScriptRoot),

    # --- shared ---------------------------------------------------------------
    [string] $OrgUrl,
    [string] $EnvironmentId,
    [string] $TenantId,

    # --- stage 1: solution ----------------------------------------------------
    [string] $SolutionUrl,
    [string] $SolutionPath,
    [string] $SharePointUrl,
    [string] $OutFile,
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
    [string] $DataverseAppId,
    [securestring] $DataverseAppSecret,
    [string] $DataverseConnectionName = 'dataverse-sp',
    [string] $SharePointConnectionName = 'sharepoint-oauth',
    [string[]] $Connection = @(),
    [ValidateRange(30, 1800)]
    [int]    $ConsentTimeoutSeconds = 300,
    [string] $SettingsFile,
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
    [string] $InstallerUrl,
    [string] $ConnectionName,
    [string] $MachineUsername,
    [securestring] $MachinePassword,
    [string] $Agent2SchemaName,
    [string] $Agent2CuaComponentSchema,
    [string] $Agent2DisplayName,
    [string] $SolutionUniqueName,
    [string] $AuthClientId,
    [securestring] $AuthClientSecret,
    [string] $AuthTenantId,
    [switch] $Interactive,
    [switch] $SkipRegistration,
    [switch] $SkipConnection,
    [switch] $SkipBinding,
    [switch] $SkipManualAuth,
    [switch] $Force,

    # --- stage 3: share and publish -------------------------------------------
    [string[]] $Agent,
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

function Write-Banner {
    param([string] $m)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $m" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}
function Write-Info { param([string] $m) Write-Host "    $m" }

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

$StatePath = Join-Path $PSScriptRoot 'handover-state.json'
$State = if (Test-Path -LiteralPath $StatePath) {
    Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
} else { [pscustomobject]@{} }
function Get-Fallback { param($Value, [string] $Key) if ($Value) { $Value } else { $State.$Key } }

try {
    # ==========================================================================
    # which stages run
    # ==========================================================================
    # Start from a real array: a pipeline that yields nothing gives $null, and
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
    if (-not ($runPrepare -or $runMachine -or $runShare)) {
        throw 'Every stage is skipped - nothing to do.'
    }

    foreach ($f in 'Prepare-Sol.ps1', 'Machine-and-Cua.ps1', 'Share-Agents.ps1') {
        $p = Join-Path $PSScriptRoot $f
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing stage script: $p" }
    }

    Write-Banner 'Hand-over deployment'
    Write-Info ("stages   " + (@(
        "$(if ($runPrepare) { '1 Prepare-Sol' } else { '1 (skipped)' })",
        "$(if ($runMachine) { '2 Machine-and-Cua' } else { '2 (skipped)' })",
        "$(if ($runShare)   { '3 Share-Agents' } else { '3 (skipped)' })"
    ) -join '  ->  '))

    # ==========================================================================
    # collect every input for the enabled stages, before anything runs
    # ==========================================================================
    Write-Banner 'Collecting inputs'

    $OrgUrl = Read-RequiredValue 'Target Dataverse org URL (https://org....crm.dynamics.com)' (Get-Fallback $OrgUrl 'OrgUrl')
    $OrgUrl = $OrgUrl.Trim().TrimEnd('/')
    if ($OrgUrl -notmatch '^https://') { throw "-OrgUrl must be an https org URL, got: $OrgUrl" }

    if ($runMachine -or ($runPrepare -and -not $SkipCreateDataverse)) {
        $TenantId = Read-RequiredValue 'Tenant id' (Get-Fallback $TenantId 'TenantId')
    }
    if ($runMachine) {
        $EnvironmentId = Read-RequiredValue 'Power Platform environment GUID' (Get-Fallback $EnvironmentId 'EnvironmentId')
    } elseif (-not $EnvironmentId) {
        $EnvironmentId = $State.EnvironmentId
    }

    # Agents: the last entry is Agent 2 unless one was named outright.
    if ($runShare -or $runMachine) {
        if (-not $Agent -or $Agent.Count -eq 0) {
            if ($State.Agents) { $Agent = @($State.Agents) }
        }
        if ((-not $Agent -or $Agent.Count -eq 0) -and $runShare) {
            $Agent = @((Read-RequiredValue 'Agent schema names, comma separated (e.g. cr720_Agent1TestScript,cr720_Agent2UITesting)' $null))
        }
        $Agent = @($Agent | ForEach-Object { $_ -split '[,\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $Agent2SchemaName) { $Agent2SchemaName = Get-Fallback $Agent2SchemaName 'Agent2SchemaName' }
        if (-not $Agent2SchemaName -and $Agent.Count) { $Agent2SchemaName = $Agent[-1] }
    }

    # --- stage 1 inputs -------------------------------------------------------
    if ($runPrepare) {
        if ($SolutionPath -and -not (Test-Path -LiteralPath $SolutionPath -PathType Leaf)) {
            throw "Not a file: $SolutionPath"
        }
        if (-not $SolutionUrl -and -not $SolutionPath) {
            $SolutionUrl = Read-RequiredValue 'Solution package https URL' (Get-Fallback $SolutionUrl 'SolutionUrl')
        }
        if (-not $SharePointUrl) { $SharePointUrl = Get-Fallback $SharePointUrl 'SharePointUrl' }

        if (-not $SkipKeyVault) {
            $SubscriptionId        = Read-RequiredValue  'Azure subscription id'                              (Get-Fallback $SubscriptionId        'SubscriptionId')
            $ResourceGroupName     = Read-RequiredValue  'Resource group name'                                (Get-Fallback $ResourceGroupName     'ResourceGroupName')
            $Location              = Read-RequiredValue  'Azure region (e.g. East US)'                        (Get-Fallback $Location              'Location')
            $KeyVaultName          = Read-RequiredValue  'Key Vault name (globally unique)'                   (Get-Fallback $KeyVaultName          'KeyVaultName')
            $AllowedEnvironmentTag = Read-RequiredValue  'AllowedEnvironments tag (<tenantId>,<environmentId>)' (Get-Fallback $AllowedEnvironmentTag 'AllowedEnvironmentTag')
            $FnoUsername           = Read-RequiredValue  'F&O username'                                       (Get-Fallback $FnoUsername           'FnoUsername')
            $FnoPassword           = Read-RequiredSecret 'F&O password'                                       $FnoPassword
        } else {
            $SubscriptionId    = Read-RequiredValue 'Azure subscription id (for the secret references)' (Get-Fallback $SubscriptionId    'SubscriptionId')
            $ResourceGroupName = Read-RequiredValue 'Resource group name'                               (Get-Fallback $ResourceGroupName 'ResourceGroupName')
            $KeyVaultName      = Read-RequiredValue 'Key Vault name'                                    (Get-Fallback $KeyVaultName      'KeyVaultName')
        }

        if (-not $SkipCreateDataverse) {
            $DataverseAppId     = Read-RequiredValue  'Dataverse connection app (client) id' (Get-Fallback $DataverseAppId 'DataverseAppId')
            $DataverseAppSecret = Read-RequiredSecret 'Dataverse app client secret'          $DataverseAppSecret
        }
    }

    # --- stage 2 inputs -------------------------------------------------------
    if ($runMachine) {
        if (-not $SkipRegistration) {
            $ApplicationId   = Read-RequiredValue  'Machine-registration app (client) id'   (Get-Fallback $ApplicationId 'ApplicationId')
            $PadClientSecret = Read-RequiredSecret 'Machine-registration app client secret' $PadClientSecret
        }
        if (-not $ConnectionName) { $ConnectionName = Get-Fallback $ConnectionName 'ConnectionName' }
        if (-not $ConnectionName) { $ConnectionName = "$MachineName-CUA" }

        if (-not $SkipConnection) {
            $MachineUsername          = Read-RequiredValue  "Windows username that signs in to $MachineName" (Get-Fallback $MachineUsername 'MachineUsername')
            $MachinePassword          = Read-RequiredSecret 'Windows password'                               $MachinePassword
            $Agent2CuaComponentSchema = Read-RequiredValue  'Agent 2 Computer Use action schema (e.g. cr720_Agent2UITesting.action.Computeruse-Computeruse)' (Get-Fallback $Agent2CuaComponentSchema 'Agent2CuaComponentSchema')
        }
        if (-not $SkipBinding) {
            $Agent2SchemaName = Read-RequiredValue 'Agent 2 schema name (schema name, NOT display name)' $Agent2SchemaName
        }
        if (-not $SkipManualAuth) {
            $Agent2DisplayName = Read-RequiredValue  "Agent 2 display name as shown in Copilot Studio (e.g. 'Agent 2 UI Testing')" (Get-Fallback $Agent2DisplayName 'Agent2DisplayName')
            $AuthClientId      = Read-RequiredValue  'Agent authentication app (client) id' (Get-Fallback $AuthClientId 'AuthClientId')
            $AuthClientSecret  = Read-RequiredSecret 'Agent authentication app client secret' $AuthClientSecret
            if (-not $AuthTenantId) { $AuthTenantId = $TenantId }
            if (-not $SolutionUniqueName) { $SolutionUniqueName = $State.SolutionUniqueName }
        }
    }

    # --- stage 3 inputs -------------------------------------------------------
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

    # ==========================================================================
    # summary
    # ==========================================================================
    Write-Banner 'Ready'
    Write-Info "org         $OrgUrl"
    if ($EnvironmentId)  { Write-Info "environment $EnvironmentId" }
    if ($runPrepare)     { Write-Info "solution    $(if ($SolutionUrl) { $SolutionUrl } else { $SolutionPath })" }
    if ($runPrepare)     { Write-Info "key vault   $(if ($SkipKeyVault) { "$KeyVaultName (reused)" } else { $KeyVaultName })" }
    if ($runMachine)     { Write-Info "machine     $MachineName  ->  connection '$ConnectionName'" }
    if ($Agent.Count)    { Write-Info "agents      $($Agent -join ', ')" }
    if ($runShare)       { Write-Info "grant       $(if ($ReportOnly) { 'report only' } elseif ($UserEmail) { $UserEmail } elseif ($RevokeUserEmail) { "revoke $RevokeUserEmail" } elseif ($RevokeEveryone) { 'revoke org-wide' } else { 'everyone in the organisation' })" }
    Write-Info 'secrets     held as SecureString, never written to disk'

    if ($WhatIfStages) {
        Write-Banner 'WhatIfStages - stopping without running anything'
        return
    }

    # ==========================================================================
    # run the stages, stopping on the first failure
    # ==========================================================================
    $stage = $null
    try {
        if ($runPrepare) {
            $stage = '1 Prepare-Sol.ps1'
            Write-Banner 'Stage 1 of 3 - Prepare-Sol.ps1'
            $a = @{
                SourceRoot               = $SourceRoot
                OrgUrl                   = $OrgUrl
                Mode                     = $Mode
                PackageType              = $PackageType
                UsernameSecretName       = $UsernameSecretName
                PasswordSecretName       = $PasswordSecretName
                DataverseConnectionName  = $DataverseConnectionName
                SharePointConnectionName = $SharePointConnectionName
                ConsentTimeoutSeconds    = $ConsentTimeoutSeconds
            }
            if ($EnvironmentId)         { $a.EnvironmentId         = $EnvironmentId }
            if ($SolutionUrl)           { $a.SolutionUrl           = $SolutionUrl }
            if ($SolutionPath)          { $a.SolutionPath          = $SolutionPath }
            if ($SharePointUrl)         { $a.SharePointUrl         = $SharePointUrl }
            if ($OutFile)               { $a.OutFile               = $OutFile }
            if ($SettingsFile)          { $a.SettingsFile          = $SettingsFile }
            if ($SubscriptionId)        { $a.SubscriptionId        = $SubscriptionId }
            if ($ResourceGroupName)     { $a.ResourceGroupName     = $ResourceGroupName }
            if ($Location)              { $a.Location              = $Location }
            if ($KeyVaultName)          { $a.KeyVaultName          = $KeyVaultName }
            if ($AllowedEnvironmentTag) { $a.AllowedEnvironmentTag = $AllowedEnvironmentTag }
            if ($FnoUsername)           { $a.FnoUsername           = $FnoUsername }
            if ($FnoPassword)           { $a.FnoPassword           = $FnoPassword }
            if ($FnoUsernameSecretUri)  { $a.FnoUsernameSecretUri  = $FnoUsernameSecretUri }
            if ($FnoPasswordSecretUri)  { $a.FnoPasswordSecretUri  = $FnoPasswordSecretUri }
            if ($DataverseAppId)        { $a.DataverseAppId        = $DataverseAppId }
            if ($TenantId)              { $a.DataverseTenantId     = $TenantId }
            if ($DataverseAppSecret)    { $a.DataverseAppSecret    = $DataverseAppSecret }
            if ($Connection.Count)      { $a.Connection            = $Connection }
            if ($SkipKeyVault)          { $a.SkipKeyVault          = $true }
            if ($SkipCreateDataverse)   { $a.SkipCreateDataverse   = $true }
            if ($SkipCreateSharePoint)  { $a.SkipCreateSharePoint  = $true }
            if ($SkipImport)            { $a.SkipImport            = $true }
            & (Join-Path $PSScriptRoot 'Prepare-Sol.ps1') @a
        }

        if ($runMachine) {
            $stage = '2 Machine-and-Cua.ps1'
            Write-Banner 'Stage 2 of 3 - Machine-and-Cua.ps1'
            $a = @{
                SourceRoot         = $SourceRoot
                OrgUrl             = $OrgUrl
                EnvironmentId      = $EnvironmentId
                TenantId           = $TenantId
                MachineName        = $MachineName
                MachineDescription = $MachineDescription
                ConnectionName     = $ConnectionName
            }
            if ($ApplicationId)            { $a.ApplicationId            = $ApplicationId }
            if ($PadClientSecret)          { $a.PadClientSecret          = $PadClientSecret }
            if ($InstallerUrl)             { $a.InstallerUrl             = $InstallerUrl }
            if ($MachineUsername)          { $a.MachineUsername          = $MachineUsername }
            if ($MachinePassword)          { $a.MachinePassword          = $MachinePassword }
            if ($Agent2SchemaName)         { $a.Agent2SchemaName         = $Agent2SchemaName }
            if ($Agent2CuaComponentSchema) { $a.Agent2CuaComponentSchema = $Agent2CuaComponentSchema }
            if ($Agent2DisplayName)        { $a.Agent2DisplayName        = $Agent2DisplayName }
            if ($SolutionUniqueName)       { $a.SolutionUniqueName       = $SolutionUniqueName }
            if ($AuthClientId)             { $a.AuthClientId             = $AuthClientId }
            if ($AuthClientSecret)         { $a.AuthClientSecret         = $AuthClientSecret }
            if ($AuthTenantId)             { $a.AuthTenantId             = $AuthTenantId }
            if ($Interactive)              { $a.Interactive              = $true }
            if ($SkipRegistration)         { $a.SkipRegistration         = $true }
            if ($SkipConnection)           { $a.SkipConnection           = $true }
            if ($SkipBinding)              { $a.SkipBinding              = $true }
            if ($SkipManualAuth)           { $a.SkipManualAuth           = $true }
            if ($Force)                    { $a.Force                    = $true }
            & (Join-Path $PSScriptRoot 'Machine-and-Cua.ps1') @a
        }

        if ($runShare) {
            $stage = '3 Share-Agents.ps1'
            Write-Banner 'Stage 3 of 3 - Share-Agents.ps1'
            $a = @{ SourceRoot = $SourceRoot; OrgUrl = $OrgUrl; Agent = $Agent }
            if ($Everyone)        { $a.Everyone        = $true }
            if ($UserEmail)       { $a.UserEmail       = $UserEmail }
            if ($RevokeUserEmail) { $a.RevokeUserEmail = $RevokeUserEmail }
            if ($RevokeEveryone)  { $a.RevokeEveryone  = $true }
            if ($NoPublish)       { $a.NoPublish       = $true }
            if ($ContinueOnError) { $a.ContinueOnError = $true }
            & (Join-Path $PSScriptRoot 'Share-Agents.ps1') @a
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
        Write-Host "  Later stages were NOT run. Fix the cause, then resume with:" -ForegroundColor Yellow
        Write-Host "      $resume" -ForegroundColor Yellow
        Write-Host "  Answers already given are cached in handover-state.json, so you will not be asked again." -ForegroundColor Yellow
        Write-Host ''
        throw
    }

    Write-Banner 'Hand-over complete'
    Write-Info 'All requested stages finished.'
}
catch {
    exit 1
}
