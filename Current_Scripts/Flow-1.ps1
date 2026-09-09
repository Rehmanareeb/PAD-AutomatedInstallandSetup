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

    # Authentication the agent ends up with. The solution package CARRIES this
    # setting, so an import overwrites whatever the target had - see the note in
    # the appendix. 'Unchanged' leaves the package and the live agent alone.
    [ValidateSet('Unchanged', 'Microsoft', 'None')]
    [string] $AuthMode = 'Unchanged',

    # Which agents -AuthMode applies to. Separate from -Bot on purpose: -Bot is the
    # list to share and publish, which is usually every agent, while authentication
    # normally should change on only one of them. Defaults to -Bot when that names
    # a single agent.
    [string[]] $AuthBot,

    # --- Fno credentials -------------------------------------------------------
    # Key Vault secret REFERENCES, not secrets. Defaults are the demo vault; pass
    # your own to point the solution somewhere else. -SkipFno leaves them alone.
    [string] $FnoUsernameValue = '/subscriptions/0c33fa37-4fa1-466d-a891-46af9e2f6e44/resourceGroups/DemoResourceGroup/providers/Microsoft.KeyVault/vaults/CUA-vault-key/secrets/Fno-Usernames',
    [string] $FnoPasswordValue = '/subscriptions/0c33fa37-4fa1-466d-a891-46af9e2f6e44/resourceGroups/DemoResourceGroup/providers/Microsoft.KeyVault/vaults/CUA-vault-key/secrets/fno-password',
    [switch] $SkipFno,

    # --- Graph app-only credentials, only needed by -ResolveLibraryId ----------
    [string] $ClientId,
    [string] $TenantId,
    [string] $ClientSecret,

    # --- agent -----------------------------------------------------------------
    # One or more agent SCHEMA names. Left empty, every agent found in the packed
    # solution is used, so a package carrying Agent 1 and Agent 2 does both.
    [string[]] $Bot,
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

# Windows PowerShell 5.1 has no 'utf8NoBOM' encoding - that name only exists in
# PowerShell 6+. A BOM in the solution's XML/JSON makes `pac solution pack` and the
# import choke, so write UTF-8 without one through .NET, which behaves the same on
# both. Set-Content appended a trailing newline, so this does too, keeping the
# packed output byte-identical to what the PowerShell 7 runs produced.
function Set-Utf8NoBom {
    param([string] $LiteralPath, [string] $Value)
    [System.IO.File]::WriteAllText($LiteralPath, $Value + [Environment]::NewLine,
                                   (New-Object System.Text.UTF8Encoding $false))
}

# 5.1 still negotiates TLS 1.0/1.1 by default on some builds; the download endpoints
# require 1.2.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

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
  -AuthMode <v>            Unchanged (default), Microsoft or None. The package
                           CARRIES the agent's authentication setting, so an
                           import overwrites the target. This solution ships
                           Agent 1 as None, which is why a freshly imported
                           agent shows "No authentication". Microsoft rewrites
                           the package AND the live agent.
  -AuthBot <schemaname>    which agent(s) -AuthMode applies to. Defaults to -Bot
                           when that names one agent; required when it names
                           several. Keep Custom Entra agents out of this list -
                           switching them discards their connection.
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
# Fno credentials - merged from Set-FnoEnvVars.ps1
# ==============================================================================

# Dataverse rejects a secret-type value that does not match this. Anchored, so
# trailing junk fails here instead of at import time with the useless message
# "This variable didn't save properly."
$SecretRefPattern = '(?i)^/subscriptions/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/resourcegroups/(.+?)/providers/Microsoft\.KeyVault/(.+?)/secrets/(.+)$'
$SecretRefHint    = 'Valid format: /subscriptions/<guid>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>/secrets/<secret>'

# Point one environmentvariabledefinition.xml at its secret, if it is an Fno one.
# Returns $null for every other variable, which is how callers know to skip it.
# Publisher prefix is matched dynamically - only the suffix is fixed.
function Set-FnoEnvVar {
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

    # Save through an XmlWriter pinned to UTF-8 without a BOM. Not $xml.Save(path),
    # which emits a BOM, and emphatically not $xml.Save(StringWriter), which stamps
    # the declaration encoding="utf-16" from the writer and makes pac fail with
    # "There is no Unicode byte order mark. Cannot switch to Unicode."
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding $false
    $settings.Indent   = $true
    $w = [System.Xml.XmlWriter]::Create($LiteralPath, $settings)
    try { $xml.Save($w) } finally { $w.Dispose() }

    [pscustomobject]@{ SchemaName = $schema; OldValue = $old; NewValue = $value }
}

# ==============================================================================
# authentication
# ==============================================================================

$AuthModeValue = @{ Microsoft = 2; None = 1 }   # bot.authenticationmode
$AuthName      = @{ 0 = 'Unspecified'; 1 = 'None (no authentication)'; 2 = 'Integrated (Authenticate with Microsoft)'; 3 = 'Custom Entra ID'; 4 = 'Generic OAuth2' }

# Rewrite the three authentication elements in a bots\<schema>\bot.xml.
# Pure string in, string out, so -SelfTest can check it with no tenant.
# The config blob is reset to the bare kind, which drops any connectionName a
# Custom Entra setup left behind - that connection does not apply to the others.
function Set-BotAuthXml {
    param(
        [string] $Xml,
        [ValidateSet('Microsoft', 'None')] [string] $To
    )
    $mode    = $AuthModeValue[$To]
    $trigger = if ($To -eq 'Microsoft') { 1 } else { 0 }   # 1 = Always, 0 = As Needed
    $cfg     = "{`n  `"`$kind`": `"BotAuthenticationConfiguration`"`n}"

    # A MatchEvaluator is used so the '$kind' in the replacement is never treated
    # as a regex substitution.
    $eval = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m) "<authenticationconfiguration>$cfg</authenticationconfiguration>"
    }
    $x = [regex]::Replace($Xml, '(?s)<authenticationconfiguration>.*?</authenticationconfiguration>', $eval)
    $x = [regex]::Replace($x, '<authenticationmode>\s*\d+\s*</authenticationmode>',       "<authenticationmode>$mode</authenticationmode>")
    $x = [regex]::Replace($x, '<authenticationtrigger>\s*\d+\s*</authenticationtrigger>', "<authenticationtrigger>$trigger</authenticationtrigger>")
    $x
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

    $sample = @'
<bot schemaname="x">
  <authenticationconfiguration>{
  "$kind": "BotAuthenticationConfiguration",
  "connectionName": "94ef9da0-33cf-4f7f-85aa-960f74342c8c"
}</authenticationconfiguration>
  <authenticationmode>1</authenticationmode>
  <authenticationtrigger>0</authenticationtrigger>
  <iconbase64>AAAA</iconbase64>
</bot>
'@
    $m = Set-BotAuthXml -Xml $sample -To Microsoft
    if ($m -notmatch '<authenticationmode>2</authenticationmode>')       { throw 'selftest: auth Microsoft should set mode 2' }
    if ($m -notmatch '<authenticationtrigger>1</authenticationtrigger>') { throw 'selftest: auth Microsoft should set trigger Always' }
    if ($m -match 'connectionName')                                      { throw 'selftest: switching auth should drop the Entra connectionName' }
    if ($m -notmatch '\$kind')                                           { throw 'selftest: the config blob must keep its $kind' }
    if ($m -notmatch '<iconbase64>AAAA</iconbase64>')                    { throw 'selftest: auth rewrite must not touch anything else' }
    # Fno: the secret-reference pattern, and the variable rewriter
    if ($FnoUsernameValue -notmatch $SecretRefPattern) { throw 'selftest: the default Fno username is not a valid secret reference' }
    if ($FnoPasswordValue -notmatch $SecretRefPattern) { throw 'selftest: the default Fno password is not a valid secret reference' }
    foreach ($bad in @(
            'not-a-path',
            '/subscriptions/nope/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv/secrets/sec',
            '/subscriptions/0c33fa37-4fa1-466d-a891-46af9e2f6e44/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv/sec',
            'https://kv.vault.azure.net/secrets/sec')) {
        if ($bad -match $SecretRefPattern) { throw "selftest: secret pattern wrongly accepted '$bad'" }
    }
    $fd = Join-Path ([IO.Path]::GetTempPath()) ("fno_" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fd -Force | Out-Null
    try {
        # existing value replaced; a different publisher prefix still matches
        $fa = Join-Path $fd 'a.xml'
        Set-Content -LiteralPath $fa -Value '<environmentvariabledefinition schemaname="abc12_FnoUsername"><defaultvalue>stale</defaultvalue><type>100000005</type></environmentvariabledefinition>'
        # no defaultvalue at all -> inserted
        $fb = Join-Path $fd 'b.xml'
        Set-Content -LiteralPath $fb -Value '<environmentvariabledefinition schemaname="abc12_FnoPassword"><type>100000005</type></environmentvariabledefinition>'
        # unrelated variable -> untouched
        $fc = Join-Path $fd 'c.xml'
        Set-Content -LiteralPath $fc -Value '<environmentvariabledefinition schemaname="abc12_ApiUrl"><defaultvalue>keepme</defaultvalue></environmentvariabledefinition>'

        $ra = Set-FnoEnvVar -LiteralPath $fa -UsernameValue 'U' -PasswordValue 'P'
        $rb = Set-FnoEnvVar -LiteralPath $fb -UsernameValue 'U' -PasswordValue 'P'
        $rc = Set-FnoEnvVar -LiteralPath $fc -UsernameValue 'U' -PasswordValue 'P'
        if ($ra.OldValue -ne 'stale') { throw 'selftest: fno existing value not read' }
        if (([xml](Get-Content -LiteralPath $fa -Raw)).environmentvariabledefinition.defaultvalue -ne 'U') { throw 'selftest: fno username not replaced' }
        if (([xml](Get-Content -LiteralPath $fb -Raw)).environmentvariabledefinition.defaultvalue -ne 'P') { throw 'selftest: fno password not inserted' }
        if (([xml](Get-Content -LiteralPath $fc -Raw)).environmentvariabledefinition.defaultvalue -ne 'keepme') { throw 'selftest: fno touched an unrelated variable' }
        if ($null -ne $rc) { throw 'selftest: fno reported an unrelated variable as changed' }
        # and the file it wrote must have no BOM
        $bytes = [System.IO.File]::ReadAllBytes($fa)
        if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw 'selftest: fno wrote a BOM' }
    } finally { Remove-Item -LiteralPath $fd -Recurse -Force -ErrorAction SilentlyContinue }

    $nn = Set-BotAuthXml -Xml $sample -To None
    if ($nn -notmatch '<authenticationmode>1</authenticationmode>')       { throw 'selftest: auth None should set mode 1' }
    if ($nn -notmatch '<authenticationtrigger>0</authenticationtrigger>') { throw 'selftest: auth None should set trigger As Needed' }

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

# --- stage 1: fetch -----------------------------------------------------------
# -SolutionUrl / -SolutionPath are the parameters; $Path is what the solution
# stage below reads. Resolve to one local zip here, once, so both sources land
# in the same place.
if ($SolutionUrl -and $SolutionPath) { throw 'Pass -SolutionUrl or -SolutionPath, not both.' }
$Path = $null
if ($SolutionUrl) {
    if ($SolutionUrl -notmatch '^https://') { throw "Refusing a non-https source: $SolutionUrl" }
    # ponytail: the downloaded zip is left in %TEMP% for the OS to reap. Add a
    # finally-block cleanup if runs ever get frequent enough to matter.
    $fetchDir = Join-Path ([IO.Path]::GetTempPath()) ("flow1_" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fetchDir -Force | Out-Null
    $Path = Join-Path $fetchDir 'solution.zip'
    Write-Stage "Fetch $SolutionUrl"
    Invoke-WebRequest -Uri $SolutionUrl -OutFile $Path -MaximumRedirection 5 -UseBasicParsing
}
elseif ($SolutionPath) {
    if (-not (Test-Path -LiteralPath $SolutionPath -PathType Leaf)) { throw "Not a file: $SolutionPath" }
    $Path = (Resolve-Path -LiteralPath $SolutionPath).Path
}
# Everything downstream unpacks and imports this file, so prove it is really a
# zip. A link that 404s saves the HTML error page under a .zip name.
if ($Path -and -not (Test-ZipSignature $Path)) { throw "Not a zip: $Path" }

$doSolution = [bool]$Path
$doImport   = $doSolution -and -not $SkipImport
# Report-only is still worth running after an import, so the caller sees what the
# freshly imported agent actually allows. -NoShare turns the whole stage off.
$doAgent    = (-not $NoShare) -and (($modes.Count -gt 0) -or (-not $doSolution) -or $doImport)

# -EnvironmentUrl is the parameter; $OrgUrl is what every stage below actually
# reads. Wire them together here, once, so both stages see the same value - the
# agent stage dereferences $OrgUrl unconditionally and would fault on $null.
$OrgUrl = if ($EnvironmentUrl) { Resolve-EnvironmentUrl $EnvironmentUrl } else { $null }
if (($doAgent -or $doImport) -and -not $OrgUrl) { throw 'Pass -EnvironmentUrl (org URL or environment GUID).' }
# Only ask up front when no solution is being unpacked. With a package, the agent
# names come from what it actually carries, which is decided after the unpack.
if ($doAgent -and -not $doSolution -and -not $Bot) {
    $Bot = @(Read-Required 'Agent schema name    (e.g. cr720_Agent1TestScript, NOT the display name)')
}
# -AuthMode is deliberately NOT applied to every agent by default: switching an
# agent off Custom Entra discards its connection, and Agent 2 uses it. So it falls
# back to -Bot only when that is unambiguous, and otherwise insists on -AuthBot.
$AuthBot = @($AuthBot | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($AuthMode -ne 'Unchanged' -and -not $AuthBot) {
    $named = @($Bot | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($named.Count -eq 1) {
        $AuthBot = $named
    } elseif ($named.Count -gt 1) {
        throw ("-Bot names $($named.Count) agents, so -AuthMode is ambiguous. Pass -AuthBot with just the agent whose " +
               "authentication should change. Changing an agent that uses Custom Entra discards its connection.")
    } else {
        throw '-AuthMode needs -AuthBot naming the agent whose authentication should change.'
    }
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
        [string] $KeepAt, [string] $GraphToken, [string[]] $BotSchema, [string] $SetAuth,
        [bool] $DoFno, [string] $FnoUser, [string] $FnoPass
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

        # What the package actually contains decides which agents get shared later,
        # so nothing has to hardcode an agent name.
        $script:PackagedBots = @(Get-ChildItem -LiteralPath (Join-Path $work 'bots') -Directory |
                                 Select-Object -ExpandProperty Name)
        Write-Host "agents in package: $($script:PackagedBots -join ', ')"

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

                $libId = Resolve-SharePointLibraryId -SiteUrl $SiteUrl -LibraryName $libName -Token $GraphToken
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

        Set-Utf8NoBom -LiteralPath $flowPath -Value ($json | ConvertTo-Json -Depth 100)
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
                Set-Utf8NoBom -LiteralPath (Join-Path $dir 'environmentvariabledefinition.xml') -Value $xml
                $changes.Add("env var: defined $($d.Name)")
            }

            # link the tools to their variable, same shape as the cre44_FnoPassword
            # link already present in this solution
            $linkFile = Join-Path $work 'Assets\botcomponent_environmentvariabledefinitionset.xml'
            # Solutions with no env-var-using component yet have no link file at all
            # (the 1_0_0_8 lineage is like this), so start one.
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

        # The package carries the agent's authentication setting, so an import
        # overwrites whatever the target environment had. This solution ships
        # Agent 1 as authenticationmode 1 (None), which is why a freshly imported
        # agent shows "No authentication". Rewrite it before packing so the
        # import lands on the mode the caller asked for.
        if ($SetAuth -ne 'Unchanged') {
            if (-not $BotSchema) { throw '-AuthMode needs -Bot, so the script knows which agent in the package to change.' }
            foreach ($bs in $BotSchema) {
                $botXml = Join-Path $work "bots\$bs\bot.xml"
                if (-not (Test-Path -LiteralPath $botXml)) {
                    throw "-AuthMode was asked for but the package has no bots\$bs\bot.xml. Check the -Bot schema name."
                }
                $before = Get-Content -LiteralPath $botXml -Raw
                $was = if ($before -match '<authenticationmode>\s*(\d+)\s*</authenticationmode>') { $Matches[1] } else { '?' }
                # Mode 3 is Custom Entra, whose config carries a connectionName that
                # switching away from it discards. Worth saying out loud.
                if ($was -eq '3' -and $SetAuth -ne 'None') {
                    $warnings.Add("auth: $bs was Custom Entra - its connectionName is being dropped. Pass only the agents you mean to change.")
                }
                Set-Utf8NoBom -LiteralPath $botXml -Value (Set-BotAuthXml -Xml $before -To $SetAuth)
                $changes.Add("auth: $bs authenticationmode $was -> $($AuthModeValue[$SetAuth]) ($SetAuth)")
            }
        }

        # --- Fno credentials, merged from Set-FnoEnvVars.ps1 ------------------
        # These are Key Vault secret REFERENCES; no secret value is written here.
        if ($DoFno) {
            $manifest = Join-Path $work 'Other\Solution.xml'
            if (-not (Test-Path -LiteralPath $manifest)) {
                throw "Unpacked solution has no Other\Solution.xml, so the publisher prefix cannot be read."
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

                # Writing the file is not enough. A component that is not listed in
                # Solution.xml RootComponents is carried in the zip and then ignored
                # by the import. 380 is Environment Variable Definition.
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
        # pac.cmd does not propagate exit codes, so a failed pack returns 0 and the
        # run would carry on and "import" a file that was never written. The zip
        # existing is the only honest proof. Long paths are the usual cause: pac is
        # still limited to 260 characters for the zip and everything under -KeepSource.
        if (-not (Test-Path -LiteralPath $Out)) {
            throw ("pac solution pack reported success but $Out does not exist. " +
                   "Check the output above - a path over 260 characters is the usual cause.")
        }

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
    if (-not $OrgUrl) {
        $OrgUrl = Read-Host 'Dataverse org URL    (e.g. https://org12345.crm.dynamics.com)'
    }
    # Read-Host returns empty when there is no console, so a non-interactive run
    # that forgot one of these would otherwise die on a null method call below.
    if (-not $SharePointUrl) { throw 'No SharePoint site URL. Pass -SharePointUrl when running non-interactively.' }
    if (-not $OrgUrl)        { throw 'No environment. Pass -EnvironmentUrl when running non-interactively.' }

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

    # Fail before unpacking anything if the secret references are malformed.
    # Dataverse otherwise accepts the import and reports "This variable didn't
    # save properly" with no clue which value was wrong.
    if (-not $SkipFno) {
        foreach ($v in @{ Username = $FnoUsernameValue; Password = $FnoPasswordValue }.GetEnumerator()) {
            if ($v.Value -notmatch $SecretRefPattern) {
                throw "Fno $($v.Key) is not a valid Key Vault secret reference: $($v.Value)`n$SecretRefHint"
            }
        }
    }

    # Graph is app-only: client id + secret, never az. The secret comes from
    # -ClientSecret, else GRAPH_CLIENT_SECRET, else a masked prompt, so it is
    # never placed on a command line by this script.
    $graphToken = $null
    if ($ResolveLibraryId) {
        if (-not $ClientId) { $ClientId = Read-Required 'Graph app registration client id' }
        if (-not $TenantId) { $TenantId = Read-Required 'Tenant id' }
        if (-not $ClientSecret) {
            $ClientSecret = $env:GRAPH_CLIENT_SECRET
            if ($ClientSecret) { Write-Host '  secret from GRAPH_CLIENT_SECRET' }
        }
        if (-not $ClientSecret) {
            $sec = Read-Host 'Client secret VALUE (input hidden)' -AsSecureString
            $ClientSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        }
        if (-not $ClientSecret) { throw 'No client secret supplied, and -ResolveLibraryId needs one.' }
        $graphToken = Get-GraphTokenAppOnly -Tenant $TenantId -App $ClientId -Secret $ClientSecret
        Write-Host "  graph token acquired app-only for $ClientId"
    }

    Invoke-SolutionStage -SrcZip $src -SiteUrl $SharePointUrl -DataverseUrl $OrgUrl -Out $OutFile `
                         -PackMode $Mode -PackType $PackageType -DoResolveLibrary ([bool]$ResolveLibraryId) `
                         -LibraryName $Library -KeepAt $KeepSource -GraphToken $graphToken `
                         -BotSchema $AuthBot -SetAuth $AuthMode `
                         -DoFno (-not $SkipFno) -FnoUser $FnoUsernameValue -FnoPass $FnoPasswordValue

    if (-not $doImport) {
        Write-Stage 'Import skipped (-SkipImport)'
    } else {
        Write-Stage "Import into $OrgUrl"
        $pacImport = Resolve-Pac
        # pac.cmd swallows exit codes, so treat "Error:" in the output as failure too.
        $out = & $pacImport solution import --environment $OrgUrl --path $OutFile `
                    --publish-changes --force-overwrite --activate-plugins --max-async-wait-time 60 2>&1 | ForEach-Object { "$_" }
        $out | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0 -or ($out -match '^\s*Error:')) {
            throw "Solution import failed. The packed solution is at $OutFile - check 'pac auth list' and import from the portal if needed."
        }
    }
}

# ==============================================================================
# STAGE 2 - agent
# ==============================================================================

if (-not $doAgent) { return }
Write-Stage 'Agent: sharing'

# Left unspecified, share every agent the package carried - that is how Agent 2
# gets shared and published alongside Agent 1 without either name being hardcoded.
if (-not $Bot -and $script:PackagedBots) {
    $Bot = $script:PackagedBots
    Write-Host "agents: $($Bot -join ', ')  (all agents in the package)"
}
if (-not $Bot) { $Bot = @(Read-Required 'Agent schema name    (e.g. cr720_Agent1TestScript, NOT the display name)') }

# "pwsh -File script.ps1 -Bot a,b" hands the whole thing over as ONE string, unlike
# a normal call from a prompt, so split on commas to make both invocations behave.
$Bot = @($Bot | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

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

# Everything below runs once per agent named in -Bot, so a solution carrying more
# than one agent gets each of them shared and published in the same run.
function Invoke-AgentStage {
    param([Parameter(Mandatory)][string] $Bot)
    Write-Host ""
    $row = (Invoke-Dv "bots?`$select=botid,name,accesscontrolpolicy,authorizedsecuritygroupids,publishedon,authenticationmode,authenticationtrigger&`$filter=schemaname eq '$Bot'").value
    if (-not $row)        { throw "No agent with schema name '$Bot' in $OrgUrl. Schema name, not display name." }
    if ($row.Count -gt 1) { throw "'$Bot' matched $($row.Count) agents." }
    Write-Host "$($row.name) [$Bot]"
    Write-Host "  policy      $($row.accesscontrolpolicy) $($PolicyName[[int]$row.accesscontrolpolicy])  $($row.authorizedsecuritygroupids)"
    Write-Host "  publishedon $($row.publishedon)"
    Write-Host "  auth        $($row.authenticationmode) $($AuthName[[int]$row.authenticationmode])"

    # Also set it on the live row. Covers "after it is already imported", and is a
    # no-op when the package rewrite above already produced this value.
    if ($AuthMode -ne 'Unchanged' -and ($AuthBot -contains $Bot) -and [int]$row.authenticationmode -ne $AuthModeValue[$AuthMode]) {
        Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{
            authenticationmode    = $AuthModeValue[$AuthMode]
            authenticationtrigger = $(if ($AuthMode -eq 'Microsoft') { 1 } else { 0 })
        } | Out-Null
        $now = (Invoke-Dv "bots($($row.botid))?`$select=authenticationmode").authenticationmode
        if ([int]$now -ne $AuthModeValue[$AuthMode]) { throw "Authentication did not stick: still $now" }
        Write-Host "  auth        set to $now $($AuthName[[int]$now])"
    }

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
    # Publish by the agent's GUID, not its schema name. --bot takes either, but the
    # id is already in hand from the row above, and it skips a name lookup that has
    # been seen to crash pac with System.ArgumentException on a freshly imported
    # agent that has never been published.
    # pac.cmd also does not propagate exit codes, so the proof of a publish is the
    # bot row's publishedon moving, not the process result.
    $pubOut = & $pac copilot publish --environment $OrgUrl --bot $row.botid 2>&1 | ForEach-Object { "$_" }
    $pubOut | ForEach-Object { Write-Host "  $_" }

    if ($pubOut -match 'non-recoverable error') {
        throw ("pac crashed while publishing $Bot. This is a fault in the CLI, not in the agent - the sharing " +
               "changes above are already written. Its own log says why: " +
               "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\<version>\tools\logs\pac-log.txt. " +
               "Publish this agent from the Copilot Studio designer, or update pac and re-run.")
    }

    $publishedon = (Invoke-Dv "bots($($row.botid))?`$select=publishedon").publishedon
    if (-not $publishedon) {
        throw ("Not published: $Bot has never been published and still has no publish date. " +
               "The sharing changes are already written. Check 'pac auth list' points at an identity " +
               "that can publish in $OrgUrl, or publish once from the designer.")
    }
    if ($row.publishedon -and [datetime]$publishedon -le [datetime]$row.publishedon) {
        throw ("Not published: publishedon is still $($row.publishedon). Check the active profile with " +
               "'pac auth list' - the change itself is already written.")
    }
    Write-Host "Published at $publishedon."
    Write-Host "An open conversation keeps working until it idles out after 30 minutes. Test with a fresh session."
}

foreach ($b in $Bot) { Invoke-AgentStage -Bot $b }


