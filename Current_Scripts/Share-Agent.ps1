<#
.SYNOPSIS
  Share a Copilot Studio agent with one user (by email) or with everyone in the
  organisation, or revoke one user, then publish.

.DESCRIPTION
  Chatting with an agent needs THREE things. Missing any one gives the user
  "You don't have access to talk to this bot, contact the owner."

    1. A security role carrying `prvReadbot`, in this environment. Measured
       2026-09-03 in this org: Environment Maker, Bot Author, Bot Viewer and
       Agent Viewer all carry it at User depth. Basic User and Microsoft
       Copilot User do NOT. A user holding any of the first four already
       passes this gate, so the script assigns Environment Maker only when
       none of the user's roles carries the privilege - that role is
       environment-wide and worth not handing out by reflex.
    2. The agent's access control policy allowing them - column
       `accesscontrolpolicy` on the bot row:

         0  Any               everyone in the organisation
         1  Copilot readers   only principals the row is shared with
         2  Group membership  members of authorizedsecuritygroupids only
         3  Any (multi-tenant)

    3. A publish. Neither the role nor the policy reaches the runtime until the
       agent is published.

  -UserEmail does all three: assigns Environment Maker if no role of theirs
  carries prvReadbot, grants them ReadAccess on the agent row, then publishes.
  Policy is left alone
  unless it is the "nobody" state - policy 2 with an empty group list, which is
  what the portal's org-wide share left behind here on 2026-09-03. That state
  ignores row shares, so it is moved to 1 and the user share becomes the gate.

  -RevokeUserEmail is the mirror image: it removes the row share and, if the
  policy is Any, narrows it to Copilot readers - because revoking a share while
  the policy says "everyone in the organisation" changes nothing. NARROWING THE
  POLICY CUTS OFF EVERY OTHER USER who is not individually shared. The role is
  left in place, since it governs the whole environment and not this one agent.

  Auth: the current `az login` for Dataverse; the active `pac auth` profile for
  the publish. Both must be in the same tenant.

.EXAMPLE
  .\Share-Agent.ps1
  Report the current policy and who the agent is shared with. Changes nothing.

.EXAMPLE
  .\Share-Agent.ps1 -UserEmail TestingUser01@InferifiDemoOrganization.onmicrosoft.com
  Share with one user and publish.

.EXAMPLE
  .\Share-Agent.ps1 -RevokeUserEmail TestingUser01@InferifiDemoOrganization.onmicrosoft.com
  Revoke one user and publish. Narrows an org-wide policy to Copilot readers.

.EXAMPLE
  .\Share-Agent.ps1 -Everyone
  Everyone in the organisation, then publish.

.EXAMPLE
  .\Share-Agent.ps1 -RevokeEveryone
  Withdraw the org-wide grant, then publish. Users who hold an individual share
  keep access and are listed; clear those with -RevokeUserEmail.
#>
[CmdletBinding()]
param(
    [string] $OrgUrl = 'https://org35fd7a12.crm.dynamics.com',   # Testing-Dyn-SP-Link
    [string] $Bot    = 'cr720_Agent1TestScript',                 # schema name, not display name
    [string] $UserEmail,
    [string] $RevokeUserEmail,
    [switch] $Everyone,
    [switch] $RevokeEveryone,
    [switch] $NoPublish,
    [switch] $SelfTest
)
$ErrorActionPreference = 'Stop'

$PolicyName = @{ 0 = 'Any (everyone in org)'; 1 = 'Copilot readers (shared principals only)'; 2 = 'Group membership'; 3 = 'Any (multi-tenant)' }

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

# Start from a real array. A pipeline that yields nothing gives $null, and $null += 'a'
# then += 'b' silently concatenates into ONE string whose .Count is 1, so the guard
# never fires and two modes both run. Bit this script on 2026-09-04.
$modes = @()
if ($UserEmail)       { $modes += 'user' }
if ($RevokeUserEmail) { $modes += 'revoke-user' }
if ($Everyone)        { $modes += 'everyone' }
if ($RevokeEveryone)  { $modes += 'revoke-everyone' }
if ($modes.Count -gt 1) { throw "Pass only one mode at a time, got: $($modes -join ', ')" }

$token = az account get-access-token --resource $OrgUrl --query accessToken -o tsv
if (-not $token) { throw 'az login first.' }
$api     = "$($OrgUrl.TrimEnd('/'))/api/data/v9.2"
$headers = @{ Authorization = "Bearer $token"; Accept = 'application/json'; 'Content-Type' = 'application/json' }

function Invoke-Dv {
    param([string] $Path, [string] $Method = 'Get', $Body)
    $call = @{ Method = $Method; Uri = "$api/$Path"; Headers = $headers }
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

$pac = (Get-Command pac, pac.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $pac) { $pac = "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\pac.cmd" }
if (-not (Test-Path $pac)) { throw 'pac not found - install from https://aka.ms/PowerAppsCLI, or publish from the designer. The change is already written.' }
# pac.cmd does not propagate the exit code and a stale auth profile prints "Error:" then returns 0,
# so the proof of a publish is the bot row's publishedon moving, not the process result.
& $pac copilot publish --environment $OrgUrl --bot $Bot 2>&1 | ForEach-Object { "  $_" } | Write-Host
$publishedon = (Invoke-Dv "bots($($row.botid))?`$select=publishedon").publishedon
if (-not $publishedon -or ($row.publishedon -and [datetime]$publishedon -le [datetime]$row.publishedon)) {
    throw "Not published: publishedon is still $($row.publishedon). Check the active profile with 'pac auth list' - the change itself is already written."
}
Write-Host "Published at $publishedon."
Write-Host "An open conversation keeps working until it idles out after 30 minutes. Test with a fresh session."
