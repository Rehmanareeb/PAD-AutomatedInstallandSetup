<#
.SYNOPSIS
  Sol_workflow_vals.ps1 and Share-Agent.ps1 merged into one file: retarget and
  pack a solution, and/or share an agent and publish it.

.DESCRIPTION
  Two stages in one script. Each runs only if you ask for it:

    Stage 1  SOLUTION   -Path <zip>
             Unpacks, rewrites the SharePoint site, the Dataverse org and
             optionally the document library id, then packs to
             <name>_Changed.zip. Prompts for any value not passed in.

    Stage 2  AGENT      -Everyone | -RevokeEveryone | -UserEmail | -RevokeUserEmail
             Shares or revokes the agent, then publishes. With no flag at all
             it reports the current policy and who the agent is shared with,
             and changes nothing.

  Pass both and they run in order: retarget, pack, then share.

  Deploy-Solution.ps1 is unchanged and still calls the two original scripts, so
  those files must stay. This is the single-file equivalent for handover.

  ACCESS CONTROL, the part that is easy to get wrong. Chatting with an agent
  needs three things, and missing any one gives the user
  "You don't have access to talk to this bot, contact the owner."

    1. A role carrying `prvReadbot`. Measured in this org: Environment Maker,
       Bot Author, Bot Viewer and Agent Viewer all carry it at User depth.
       Basic User and Microsoft Copilot User do NOT. The script assigns
       Environment Maker only when none of the user's roles carries it.
    2. The agent's `accesscontrolpolicy`:
         0 Any (everyone in org)   1 Copilot readers (shared principals only)
         2 Group membership        3 Any (multi-tenant)
       Policy 2 with an empty group list means NOBODY.
    3. A publish. Nothing above reaches the runtime until the agent is published.

.NOTES
  ENVIRONMENT REQUIREMENTS - see the appendix at the bottom of this file.
  Deploy-Solution.ps1 is unchanged and still calls the two original scripts.
#>
[CmdletBinding()]
param(
    [switch] $Help,

    # --- source ----------------------------------------------------------------
    [string] $SolutionUrl,
    [string] $SolutionPath,

    # --- target ----------------------------------------------------------------
    # Accepts an https org URL or a bare environment GUID.
    [string] $EnvironmentUrl,
    [string] $SharePointUrl,
    [string] $OutFile,
    [ValidateSet('literal', 'envvar')]
    [string] $Mode = 'literal',
    [ValidateSet('Unmanaged', 'Managed', 'Both')]
    [string] $PackageType = 'Unmanaged',
    [switch] $ResolveLibraryId,
    [string] $Library,
    [string] $KeepSource,

    # --- Graph app-only credentials, only needed by -ResolveLibraryId ----------
    [string] $ClientId,
    [string] $TenantId,
    [string] $ClientSecret,

    # --- agent -----------------------------------------------------------------
    [string] $UserEmail,
    [string] $RevokeUserEmail,
    [switch] $Everyone,
    [switch] $RevokeEveryone,
    [switch] $NoPublish,

    # --- flow control ----------------------------------------------------------
    [switch] $SkipImport,
    [switch] $NoShare,
    [switch] $SelfTest
)
$ErrorActionPreference = 'Stop'

$EvSharePoint = 'cre44_SharePointSiteUrl'
$EvOrg        = 'cre44_DataverseOrgUrl'
$EvLibrary    = 'cre44_SharePointLibraryId'

$PolicyName = @{ 0 = 'Any (everyone in org)'; 1 = 'Copilot readers (shared principals only)'; 2 = 'Group membership'; 3 = 'Any (multi-tenant)' }

function Write-Stage { param([string] $Text) Write-Host "`n=== $Text" -ForegroundColor Cyan }

# ==============================================================================
# -Help
# ==============================================================================
if ($Help) {
    @'
Flow-1.ps1 - fetch a Copilot Studio solution, retarget it, import it, share the agent.

USAGE
  .\Flow-1.ps1 -SolutionUrl <https url> -EnvironmentUrl <org url or guid> [options]
  .\Flow-1.ps1 -Help          this text
  .\Flow-1.ps1 -SelfTest      offline checks, touches nothing

  Anything required but not passed is prompted for. Nothing is hardcoded.

WHAT IT DOES, in order
  1 fetch     downloads the solution zip, or takes a local -SolutionPath
  2 prompt    asks for whatever you did not supply
  3 retarget  rewrites SharePoint site, Dataverse org, optionally library id
  4 pack      writes <name>_Changed.zip
  5 import    pac solution import, publishing changes   (-SkipImport to skip)
  6 share     shares the agent and publishes            (-NoShare to skip)

SOURCE  (one of)
  -SolutionUrl <url>       https link to the solution zip, e.g. a catbox link
  -SolutionPath <file>     local zip instead of downloading

TARGET
  -EnvironmentUrl <v>      https://orgXXXX.crm.dynamics.com, or the environment GUID
  -SharePointUrl <url>     https://<tenant>.sharepoint.com/sites/<site>
  -Bot <schemaname>        agent SCHEMA name, e.g. cr720_Agent1TestScript
                           (not the display name "Agent 1 Test Script")

SOLUTION OPTIONS
  -ResolveLibraryId        look the document library id up on the target site.
                           Needs the Graph credentials below.
  -Library <name>          library to resolve; defaults to the one the flow uses
  -Mode literal|envvar     literal writes values in; envvar exposes them as
                           environment variables. Default literal.
  -PackageType <t>         Unmanaged (default), Managed or Both
  -OutFile <path>          where to write the packed zip
  -KeepSource <dir>        keep the unpacked folder for diffing

GRAPH CREDENTIALS  (app-only, only used by -ResolveLibraryId)
  -ClientId <guid>         app registration id
  -TenantId <guid>         tenant id
  -ClientSecret <value>    prefer NOT to pass this. Set GRAPH_CLIENT_SECRET
                           instead, or let the script prompt with masked input.
  The app needs Sites.Read.All as an APPLICATION permission, admin consented.

AGENT SHARING  (pick at most one)
  -Everyone                everyone in the organisation can chat
  -RevokeEveryone          withdraw that; individual shares survive
  -UserEmail <upn>         share with one user, granting a role if they need one
  -RevokeUserEmail <upn>   revoke one user
  -NoPublish               write the change but do not publish it
  With none of these, the agent step reports current access and changes nothing.

EXAMPLES
  .\Flow-1.ps1 -SolutionUrl https://files.catbox.moe/abc.zip `
               -EnvironmentUrl https://org35fd7a12.crm.dynamics.com `
               -SharePointUrl https://contoso.sharepoint.com/sites/AICOE `
               -Bot cr720_Agent1TestScript -Everyone

  .\Flow-1.ps1 -SolutionPath .\Solution.zip -EnvironmentUrl <guid> `
               -ResolveLibraryId -ClientId <guid> -TenantId <guid> `
               -SkipImport -NoShare

  .\Flow-1.ps1 -EnvironmentUrl https://org35fd7a12.crm.dynamics.com `
               -Bot cr720_Agent1TestScript
    Report who can use the agent. Changes nothing.

REQUIREMENTS
  Operator needs System Administrator in the target environment.
  A user being shared with needs a role carrying prvReadbot plus a Copilot
  Studio licence. Full list in the appendix at the bottom of this file.
'@ | Write-Host
    return
}

# ==============================================================================
# helpers
# ==============================================================================

function Resolve-Pac {
    foreach ($n in 'pac', 'pac.cmd', 'pac.exe') {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    $candidates = @(
        "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\pac.cmd"
        "$env:USERPROFILE\.dotnet\tools\pac.exe"
        "${env:ProgramFiles}\Microsoft Power Platform CLI\pac.exe"
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    throw "pac (Power Platform CLI) not found. Install it with: winget install Microsoft.PowerPlatformCLI"
}

function Read-Required {
    param([string] $Prompt)
    do { $a = (Read-Host $Prompt).Trim() } while (-not $a)
    $a
}

# Everything downstream unpacks and imports this file, so check it really is a
# zip before trusting it. PK\x03\x04 is the local file header of every zip.
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

# An environment may be given as an org URL or as a bare GUID. Normalise to the
# org URL, which is what the Dataverse Web API needs.
function Resolve-EnvironmentUrl {
    param([string] $Value)
    $v = $Value.Trim().TrimEnd('/')
    if ($v -match '^https://[^/]+\.dynamics\.com$') { return $v }
    if ($v -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "Environment must be https://<org>.crm.dynamics.com or an environment GUID, got '$Value'"
    }
    $t = az account get-access-token --resource https://service.powerapps.com/ --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $t) { throw "az could not get a token to resolve environment $v. Run 'az login'." }
    $u = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$($v)?api-version=2021-04-01"
    try { $env = Invoke-RestMethod -Uri $u -Headers @{ Authorization = "Bearer $t" } }
    catch { throw "Could not look up environment $v : $($_.Exception.Message)" }
    $url = $env.properties.linkedEnvironmentMetadata.instanceUrl
    if (-not $url) { throw "Environment $v has no Dataverse database." }
    $url.TrimEnd('/')
}

# --- Graph, app-only ----------------------------------------------------------
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
    return $hit[0].id
}

# ==============================================================================
# policy rules - pure, and the only thing -SelfTest can check without a tenant
# ==============================================================================

# Can a user SHARE take effect under the current policy?
# Only the "nobody" state - group membership with no groups - is corrected.
function Get-SharePolicyFix {
    param([int] $Policy, [string] $Groups)
    if ($Policy -eq 2 -and [string]::IsNullOrWhiteSpace($Groups)) { return @{ Set = 1; Warn = $null } }
    if ($Policy -eq 2) {
        return @{ Set = $null; Warn = "Policy is Group membership ($Groups). A user share is IGNORED - add the user to one of those Entra groups, or re-run with -Everyone." }
    }
    @{ Set = $null; Warn = $null }
}

# Can a user REVOKE take effect under the current policy?
# Any/Any-multi-tenant lets everyone chat regardless of shares, so narrow to Copilot readers.
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

if ($SelfTest) {
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
    'ok'; return
}

# --- which stages run ---------------------------------------------------------
# Start from a real array. A pipeline that yields nothing gives $null, and
# $null += 'a' then += 'b' concatenates into ONE string whose .Count is 1, so a
# guard built that way never fires and two modes both run. Bit this on 2026-09-04.
$modes = @()
if ($UserEmail)       { $modes += 'user' }
if ($RevokeUserEmail) { $modes += 'revoke-user' }
if ($Everyone)        { $modes += 'everyone' }
if ($RevokeEveryone)  { $modes += 'revoke-everyone' }
if ($modes.Count -gt 1) { throw "Pass only one agent mode at a time, got: $($modes -join ', ')" }

$doSolution = [bool]$Path
$doAgent    = ($modes.Count -gt 0) -or (-not $doSolution)



function Resolve-SharePointLibraryId {
    param([string] $SiteUrl, [string] $LibraryName)

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) not found, needed by -ResolveLibraryId. Install it, or drop the switch and set the library id by hand.'
    }
    $token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "az could not get a Microsoft Graph token. Run 'az login' as an account that can read the target site.`n$token"
    }
    $h = @{ Authorization = "Bearer $token"; Accept = 'application/json' }

    $u = [uri] $SiteUrl
    try {
        $site = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$($u.Host):$($u.AbsolutePath)" -Headers $h
    }
    catch {
        throw "Could not read site $SiteUrl via Graph: $($_.Exception.Message). Check the URL and that this account has access."
    }

    $lists = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/lists?`$select=id,displayName,name" -Headers $h
    # 'name' is the URL segment ('Shared Documents'), 'displayName' the title ('Documents')
    $hit = @($lists.value | Where-Object { $_.name -eq $LibraryName -or $_.displayName -eq $LibraryName })

    if ($hit.Count -eq 0) {
        throw ("No library '$LibraryName' on $SiteUrl. Available:`n" +
               (($lists.value | ForEach-Object { "    $($_.displayName)  (url: $($_.name))" }) -join "`n"))
    }
    if ($hit.Count -gt 1) { throw "'$LibraryName' matches $($hit.Count) lists on $SiteUrl." }
    return $hit[0].id
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
    }
    else {
        $Definition.parameters | Add-Member -NotePropertyName $key -NotePropertyValue $decl
    }
    return "@parameters('$key')"
}

function Set-ToolInput {
    param([string] $File, [string] $Prop, [string] $Value)

    $lines    = [System.IO.File]::ReadAllLines($File)
    $inInputs = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^inputs:\s*$') { $inInputs = $true; continue }
        if ($inInputs -and $lines[$i] -match '^\S') { break }   # next top-level key
        if ($inInputs -and $lines[$i] -match ("^\s*propertyName:\s*" + [regex]::Escape($Prop) + "\s*$")) {
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
    return $false
}

function Invoke-SolutionStage {
    param(
        [string] $SrcZip, [string] $SiteUrl, [string] $DataverseUrl, [string] $Out,
        [string] $PackMode, [string] $PackType, [bool] $DoResolveLibrary, [string] $LibraryName,
        [string] $KeepAt
    )
    # The original script ran under StrictMode; keep that scoped to this stage so
    # the agent stage behaves exactly as it did before the merge.
    Set-StrictMode -Version Latest

    $pac      = Resolve-Pac
    $changes  = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $tmp  = Join-Path ([IO.Path]::GetTempPath()) ("prepsol_" + [Guid]::NewGuid().ToString('N'))
    $work = if ($KeepAt) { $KeepAt } else { Join-Path $tmp 'src' }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }

    try {
        & $pac solution unpack --zipfile $SrcZip --folder $work --packagetype $PackType
        if ($LASTEXITCODE -ne 0) { throw "pac solution unpack failed (exit $LASTEXITCODE)" }
        Write-Host "unpacked $((Get-ChildItem -LiteralPath $work -Recurse -File).Count) files"

        $flow = @(Get-ChildItem -LiteralPath (Join-Path $work 'Workflows') -Filter 'Save-Generated-CSV-To-SharePoint-*.json' -File)
        if ($flow.Count -ne 1) { throw "Expected exactly one Agent-1 CSV flow, found $($flow.Count)" }
        $flowPath = $flow[0].FullName

        $json = Get-Content -LiteralPath $flowPath -Raw | ConvertFrom-Json
        $defn = $json.properties.definition

        if ($PackMode -eq 'envvar') {
            $siteValue = Add-FlowParameter -Definition $defn -Name $EvSharePoint -Value $SiteUrl
        }
        else {
            # literal is the inverse of envvar: drop any environment variable
            # declarations so re-running over an envvar package comes out clean
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
            # Compose actions carry a plain string in .inputs, not an object
            if ($inputs -is [string] -or $null -eq $inputs) { continue }
            if ($inputs.PSObject.Properties.Name -notcontains 'parameters') { continue }
            $p     = $inputs.parameters
            $names = $p.PSObject.Properties.Name

            # remember the library the flow writes into, e.g. '/Shared Documents/Test Cases'
            if (-not $folderHint -and $names -contains 'folderPath' -and
                $p.folderPath -is [string] -and $p.folderPath.StartsWith('/')) {
                $folderHint = $p.folderPath
            }
            if ($names -contains 'table') { $tableParams += $p }

            if ($names -notcontains 'dataset') { continue }
            $cur = $p.dataset
            # match either form we may have written before
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

                $libId = Resolve-SharePointLibraryId -SiteUrl $SiteUrl -LibraryName $libName
                $changes.Add("library: resolved '$libName' on the target site -> $libId")

                $tableValue = $libId
                if ($PackMode -eq 'envvar') {
                    $tableValue = Add-FlowParameter -Definition $defn -Name $EvLibrary -Value $libId
                    $libEnvDef  = @{ Name = $EvLibrary; Value = $libId; Display = 'SharePoint Library Id' }
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

        ($json | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $flowPath -Encoding utf8NoBOM
        $changes.Add("flow: set $n SharePoint site value(s) in $($flow[0].Name)")

        $tools = @(
            @{ Glob = '*Agent1TestScript.action.SharePoint-Createfile'
               Prop = 'dataset';      Literal = $SiteUrl;      Ev = $EvSharePoint; Label = 'SharePoint file tool' }
            @{ Glob = '*Agent1TestScript.action.MicrosoftDataverse-Addanewrowtoselectedenvironment'
               Prop = 'organization'; Literal = $DataverseUrl; Ev = $EvOrg;        Label = 'Dataverse row tool' }
        )

        $evLinks = @()
        foreach ($t in $tools) {
            $dir = @(Get-ChildItem -LiteralPath (Join-Path $work 'botcomponents') -Filter $t.Glob -Directory)
            if ($dir.Count -ne 1) { throw "Expected exactly one $($t.Label), found $($dir.Count)" }
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
                @{ Name = $EvSharePoint; Value = $SiteUrl;      Display = 'SharePoint Site URL' }
                @{ Name = $EvOrg;        Value = $DataverseUrl; Display = 'Dataverse Org URL' }
            )
            # only present when -ResolveLibraryId actually looked one up
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
                Set-Content -LiteralPath (Join-Path $dir 'environmentvariabledefinition.xml') -Value $xml -Encoding utf8NoBOM
                $changes.Add("env var: defined $($d.Name)")
            }

            # link the tools to their variable, same shape as the cre44_FnoPassword
            # link already present in this solution
            $linkFile = Join-Path $work 'Assets\botcomponent_environmentvariabledefinitionset.xml'
            # Solutions with no env-var-using component yet have no link file at all
            # (the 1_0_0_8 lineage is like this), so start one.
            if ($evLinks.Count -and -not (Test-Path -LiteralPath $linkFile)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $linkFile) -Force | Out-Null
                Set-Content -LiteralPath $linkFile -Encoding utf8NoBOM `
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
                    Set-Content -LiteralPath $linkFile -Value $x -Encoding utf8NoBOM
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
                    if ($nx -ne $lx) { Set-Content -LiteralPath $dvLink -Value $nx -Encoding utf8NoBOM }
                }

                $changes.Add("import fix: removed search config for missing app '$app'")
                $removedAny = $true
            }
        }
        if (-not $removedAny) { $changes.Add('import fix: nothing to remove (no orphaned app search config)') }

        if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
        & $pac solution pack --zipfile $Out --folder $work --packagetype $PackType
        if ($LASTEXITCODE -ne 0) { throw "pac solution pack failed (exit $LASTEXITCODE)" }

        Write-Host ''
        $changes  | ForEach-Object { Write-Host "  - $_" }
        $warnings | ForEach-Object { Write-Warning $_ }
        Write-Host ''
        Write-Host "wrote $Out"
        if ($KeepAt) { Write-Host "unpacked source kept at $work" }
        Write-Host "mode: $PackMode"
        if ($PackMode -eq 'envvar') {
            Write-Host 'NOTE: open the flow in the designer after import and confirm the'
            Write-Host '      SharePoint site field resolves to the environment variable.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($doSolution) {
    Write-Stage 'Solution: retarget values and pack'

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Not a file: $Path" }
    $src = (Resolve-Path -LiteralPath $Path).Path

    # Prompt for anything not supplied. -OrgUrl has a default for the agent stage,
    # so only prompt when the caller did not name it explicitly.
    if (-not $SharePointUrl) {
        $SharePointUrl = Read-Host 'SharePoint site URL  (e.g. https://contoso.sharepoint.com/sites/AICOE)'
    }
    if (-not $PSBoundParameters.ContainsKey('OrgUrl')) {
        $answer = Read-Host "Dataverse org URL    (ENTER for $OrgUrl)"
        if ($answer.Trim()) { $OrgUrl = $answer }
    }

    $SharePointUrl = $SharePointUrl.Trim().TrimEnd('/')
    $OrgUrl        = $OrgUrl.Trim().TrimEnd('/')

    if ($SharePointUrl -notmatch '^https://[^/]+\.sharepoint\.com/sites/.+') {
        throw "SharePoint URL should look like https://<tenant>.sharepoint.com/sites/<site>"
    }
    if ($OrgUrl -notmatch '^https://[^/]+\.dynamics\.com$') {
        throw "Dataverse org URL should look like https://<org>.crm.dynamics.com"
    }

    if (-not $OutFile) {
        $base    = [IO.Path]::GetFileNameWithoutExtension($src)
        $OutFile = Join-Path (Split-Path -Parent $src) "${base}_Changed.zip"
    }

    Invoke-SolutionStage -SrcZip $src -SiteUrl $SharePointUrl -DataverseUrl $OrgUrl -Out $OutFile `
                         -PackMode $Mode -PackType $PackageType -DoResolveLibrary ([bool]$ResolveLibraryId) `
                         -LibraryName $Library -KeepAt $KeepSource
}

# ==============================================================================
# STAGE 2 - agent
# ==============================================================================

if (-not $doAgent) { return }
Write-Stage 'Agent: sharing'

$OrgUrl = $OrgUrl.Trim().TrimEnd('/')
$token = az account get-access-token --resource $OrgUrl --query accessToken -o tsv
if (-not $token) { throw 'az login first.' }
$api     = "$OrgUrl/api/data/v9.2"
$headers = @{ Authorization = "Bearer $token"; Accept = 'application/json'; 'Content-Type' = 'application/json' }

function Invoke-Dv {
    param([string] $ApiPath, [string] $Method = 'Get', $Body)
    $call = @{ Method = $Method; Uri = "$api/$ApiPath"; Headers = $headers }
    if ($null -ne $Body) { $call.Body = ($Body | ConvertTo-Json -Depth 6) }
    Invoke-RestMethod @call
}

function Resolve-DvUser {
    param([string] $Email)
    $e = $Email.Trim()
    $u = (Invoke-Dv ("systemusers?`$select=systemuserid,fullname,domainname,_businessunitid_value&`$filter=" +
                     "domainname eq '$e' or internalemailaddress eq '$e'")).value
    if (-not $u)        { throw "No user '$e' in $OrgUrl. They must already exist in this environment - add them in the Power Platform admin center first." }
    if ($u.Count -gt 1) { throw "'$e' matched $($u.Count) users." }
    $u
}

function Get-SharedPrincipals {
    param([hashtable] $Target)
    (Invoke-Dv ("RetrieveSharedPrincipalsAndAccess(Target=@t)?@t=" + [uri]::EscapeDataString(($Target | ConvertTo-Json -Compress)))).PrincipalAccesses
}

$row = (Invoke-Dv "bots?`$select=botid,name,accesscontrolpolicy,authorizedsecuritygroupids,publishedon&`$filter=schemaname eq '$Bot'").value
if (-not $row)        { throw "No agent with schema name '$Bot' in $OrgUrl. Schema name, not display name." }
if ($row.Count -gt 1) { throw "'$Bot' matched $($row.Count) agents." }
Write-Host "$($row.name) [$Bot]"
Write-Host "  policy      $($row.accesscontrolpolicy) $($PolicyName[[int]$row.accesscontrolpolicy])  $($row.authorizedsecuritygroupids)"
Write-Host "  publishedon $($row.publishedon)"

$target = @{ '@odata.id' = "bots($($row.botid))" }

if ($modes.Count -eq 0) {
    Write-Host "  shared with"
    foreach ($p in Get-SharedPrincipals $target) {
        $id   = $p.Principal.ownerid
        $type = $p.Principal.'@odata.type' -replace '.*\.', ''
        $who  = if ($type -eq 'systemuser') { (Invoke-Dv "systemusers($id)?`$select=domainname").domainname }
                else { "$((Invoke-Dv "teams($id)?`$select=name").name) (team)" }
        Write-Host "    $who - $($p.AccessMask)"
    }
    return
}

if ($Everyone) {
    Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{ accesscontrolpolicy = 0; authorizedsecuritygroupids = $null } | Out-Null
    Write-Host "Policy set to 0 $($PolicyName[0])."
}

if ($RevokeEveryone) {
    # The mirror of -Everyone: withdraw the org-wide grant by moving the policy to
    # Copilot readers. Individual row shares survive on purpose - they are separate
    # grants, and clearing them is -RevokeUserEmail's job, one user at a time.
    Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{ accesscontrolpolicy = 1; authorizedsecuritygroupids = $null } | Out-Null
    Write-Host "Org-wide access withdrawn. Policy set to 1 $($PolicyName[1])."
    $left = Get-SharedPrincipals $target | Where-Object { $_.Principal.'@odata.type' -match 'systemuser' }
    if ($left) {
        Write-Host "  these users keep access through an individual share:"
        foreach ($p in $left) { Write-Host "    $((Invoke-Dv "systemusers($($p.Principal.ownerid))?`$select=domainname").domainname)" }
        Write-Host "  clear each with -RevokeUserEmail, or leave them if they should keep it."
    } else {
        Write-Host "  no individual user shares remain - only the owner team can use the agent."
    }
}

if ($UserEmail) {
    $user = Resolve-DvUser $UserEmail
    Write-Host "Share with: $($user.fullname) <$($user.domainname)>"

    # 1. prvReadbot, the privilege that lets the user see the agent at all.
    #    Only grant a role if none of theirs already carries it - Environment Maker
    #    is environment-wide, and Bot Author / Bot Viewer / Agent Viewer carry it too.
    $userRoles  = (Invoke-Dv "systemusers($($user.systemuserid))/systemuserroles_association?`$select=name,roleid").value
    $prvReadBot = (Invoke-Dv "privileges?`$select=privilegeid&`$filter=name eq 'prvReadbot'").value[0].privilegeid
    $holder     = $userRoles | Where-Object {
        (Invoke-Dv "RetrieveRolePrivilegesRole(RoleId=$($_.roleid))").RolePrivileges.PrivilegeId -contains $prvReadBot
    } | Select-Object -First 1
    if ($holder) {
        Write-Host "  role   $($holder.name) already carries prvReadbot"
    } else {
        $role = (Invoke-Dv ("roles?`$select=roleid&`$filter=name eq 'Environment Maker' and _businessunitid_value eq $($user._businessunitid_value)")).value
        if (-not $role) { throw "No Environment Maker role in the user's business unit. Assign a role carrying prvReadbot by hand." }
        Invoke-Dv "systemusers($($user.systemuserid))/systemuserroles_association/`$ref" -Method Post -Body @{ '@odata.id' = "$api/roles($($role[0].roleid))" } | Out-Null
        Write-Host "  role   Environment Maker assigned - no existing role carried prvReadbot (had: $($userRoles.name -join ', '))"
    }

    # 2. Read access on the agent row.
    Invoke-Dv 'GrantAccess' -Method Post -Body @{
        Target          = $target
        PrincipalAccess = @{ Principal = @{ '@odata.id' = "systemusers($($user.systemuserid))" }; AccessMask = 'ReadAccess' }
    } | Out-Null
    Write-Host "  share  ReadAccess granted on the agent"

    # 3. Policy, only if it would swallow the share.
    $fix = Get-SharePolicyFix -Policy ([int]$row.accesscontrolpolicy) -Groups $row.authorizedsecuritygroupids
    if ($fix.Warn) { Write-Warning $fix.Warn }
    if ($null -ne $fix.Set) {
        Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{ accesscontrolpolicy = $fix.Set } | Out-Null
        Write-Host "  policy was 2 with no groups (nobody) - set to $($fix.Set) $($PolicyName[$fix.Set])"
    } else {
        Write-Host "  policy left at $($row.accesscontrolpolicy) $($PolicyName[[int]$row.accesscontrolpolicy])"
    }
}

if ($RevokeUserEmail) {
    $user = Resolve-DvUser $RevokeUserEmail
    Write-Host "Revoke: $($user.fullname) <$($user.domainname)>"

    # 1. Drop the row share, then prove it is gone.
    Invoke-Dv 'RevokeAccess' -Method Post -Body @{
        Target  = $target
        Revokee = @{ '@odata.id' = "systemusers($($user.systemuserid))" }
    } | Out-Null
    $still = Get-SharedPrincipals $target | Where-Object { $_.Principal.ownerid -eq $user.systemuserid }
    if ($still) { throw "RevokeAccess returned success but the share is still there: $($still.AccessMask)" }
    Write-Host "  share  revoked on the agent"

    # 2. Policy, if it would make the revoke meaningless.
    $fix = Get-RevokePolicyFix -Policy ([int]$row.accesscontrolpolicy) -Groups $row.authorizedsecuritygroupids
    if ($fix.Warn) { Write-Warning $fix.Warn }
    if ($null -ne $fix.Set) {
        Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{ accesscontrolpolicy = $fix.Set } | Out-Null
        Write-Host "  policy narrowed to $($fix.Set) $($PolicyName[$fix.Set])"
    } else {
        Write-Host "  policy left at $($row.accesscontrolpolicy) $($PolicyName[[int]$row.accesscontrolpolicy])"
    }

    # The environment role is deliberately left alone - it governs every agent here, not this one.
    Write-Host "  role   left as is. Environment Maker governs the whole environment, not this agent."
}

$after = Invoke-Dv "bots($($row.botid))?`$select=accesscontrolpolicy,authorizedsecuritygroupids"
Write-Host "Now: policy=$($after.accesscontrolpolicy) $($PolicyName[[int]$after.accesscontrolpolicy]) $($after.authorizedsecuritygroupids)"

if ($NoPublish) {
    Write-Host "NOT published (-NoPublish). Nothing above reaches the runtime until you run:"
    Write-Host "    pac copilot publish --environment $OrgUrl --bot $Bot"
    return
}

$pac = Resolve-Pac
# pac.cmd does not propagate the exit code and a stale auth profile prints "Error:" then returns 0,
# so the proof of a publish is the bot row's publishedon moving, not the process result.
& $pac copilot publish --environment $OrgUrl --bot $Bot 2>&1 | ForEach-Object { "  $_" } | Write-Host
$publishedon = (Invoke-Dv "bots($($row.botid))?`$select=publishedon").publishedon
if (-not $publishedon -or ($row.publishedon -and [datetime]$publishedon -le [datetime]$row.publishedon)) {
    throw "Not published: publishedon is still $($row.publishedon). Check the active profile with 'pac auth list' - the change itself is already written."
}
Write-Host "Published at $publishedon."
Write-Host "An open conversation keeps working until it idles out after 30 minutes. Test with a fresh session."


