<#
.SYNOPSIS
  Hand-over step 3, standalone: share the agents and publish them. Flow step 5.

.DESCRIPTION
  Self-contained. It calls no other script in this repo.

  For each agent named in -Agent, in order: report the current access, apply the
  requested grant, then publish. Publish last, because nothing above reaches the
  runtime until a publish.

      5.1  share and publish Agent 1
      5.2  share and publish Agent 2
      5.3  end-to-end validation checklist

  ACCESS CONTROL, the part that is easy to get wrong. Chatting with an agent
  needs THREE things, and missing any one gives the user "You don't have access
  to talk to this bot, contact the owner":

    1. A security role carrying `prvReadbot`. Measured in this org: Environment
       Maker, Bot Author, Bot Viewer and Agent Viewer all carry it at User
       depth. Basic User and Microsoft Copilot User do NOT. A user holding any
       of the first four already passes, so -UserEmail assigns Environment Maker
       only when none of their existing roles carries the privilege - that role
       is environment-wide and worth not handing out by reflex.
    2. The agent's access control policy allowing them - the accesscontrolpolicy
       column on the bot row:
         0  Any               everyone in the organisation
         1  Copilot readers   only principals the row is shared with
         2  Group membership  members of authorizedsecuritygroupids only
         3  Any (multi-tenant)
       Policy 2 with an EMPTY group list means NOBODY, and it ignores row
       shares. That is the state the portal's org-wide share has been seen to
       leave behind, so -UserEmail moves it to 1 and lets the share be the gate.
    3. A publish.

  -RevokeUserEmail is the mirror image: it removes the row share and, if the
  policy is Any, narrows it to Copilot readers - because revoking a share while
  the policy says "everyone in the organisation" changes nothing. NARROWING THE
  POLICY CUTS OFF EVERY OTHER USER who is not individually shared. The role is
  left in place, since it governs the whole environment and not this one agent.

  With no grant switch at all this reports the current policy and shares for
  each agent and changes nothing - the safe way to check where a deployment got
  to.

  Run this AFTER Machine-and-Cua.ps1. Publishing before the Computer Use binding
  exists ships an agent whose tool has no machine.

  REQUIRES: `az login` for the Dataverse calls, and a `pac auth` profile for the
  publish. Both in the same tenant as the target environment.

.PARAMETER OrgUrl
  Target Dataverse org URL, e.g. https://org35fd7a12.crm.dynamics.com

.PARAMETER Agent
  Schema names of the agents to share and publish, in order. Schema names, not
  display names. Prompted for if omitted; comma or space separated.

.PARAMETER Everyone
  Share with everyone in the organisation - sets accesscontrolpolicy to 0. This
  is what the flow's "share both agents with the organization" step does.

.PARAMETER UserEmail
  Share with one user instead, by email. Assigns a role carrying prvReadbot if
  none of theirs already does, grants ReadAccess on the agent row, and corrects
  a "nobody" policy.

.PARAMETER RevokeUserEmail
  Revoke one user. Read the warning about policy narrowing above.

.PARAMETER RevokeEveryone
  Withdraw the org-wide grant, moving the policy to Copilot readers. Individual
  row shares survive on purpose - clear those one at a time with
  -RevokeUserEmail.

.PARAMETER NoPublish
  Write the sharing change and stop. Nothing reaches the runtime until a
  publish, so use this only when you intend to publish separately.

.PARAMETER ContinueOnError
  Carry on to the next agent if one fails, instead of stopping. Failures are
  reported at the end and the script exits non-zero.

.PARAMETER SelfTest
  Run the policy rules against their known cases and exit. Needs no tenant.

.EXAMPLE
  .\Share-Agents.ps1 -OrgUrl https://org35fd7a12.crm.dynamics.com `
                     -Agent cr720_Agent1TestScript,cr720_Agent2UITesting -Everyone

  Share both agents with the organisation and publish both.

.EXAMPLE
  .\Share-Agents.ps1 -Agent cr720_Agent1TestScript,cr720_Agent2UITesting

  Report only. Shows the current policy and who each agent is shared with.

.EXAMPLE
  .\Share-Agents.ps1 -Agent cr720_Agent2UITesting -UserEmail tester@contoso.com

  Share one agent with one user, then publish it.

.EXAMPLE
  .\Share-Agents.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [switch] $Help,

    [string]   $OrgUrl,
    [string[]] $Agent,

    [switch] $Everyone,
    [string] $UserEmail,
    [string] $RevokeUserEmail,
    [switch] $RevokeEveryone,

    [switch] $NoPublish,
    [switch] $ContinueOnError,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$PolicyName = @{
    0 = 'Any (everyone in org)'
    1 = 'Copilot readers (shared principals only)'
    2 = 'Group membership'
    3 = 'Any (multi-tenant)'
}

function Write-Stage { param([string] $m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Info  { param([string] $m) Write-Host "    $m" }
function Write-Ok    { param([string] $m) Write-Host "    $m" -ForegroundColor Green }


function Get-SharePolicyFix {
    param([int] $Policy, [string] $Groups)
    if ($Policy -eq 2 -and [string]::IsNullOrWhiteSpace($Groups)) { return @{ Set = 1; Warn = $null } }
    if ($Policy -eq 2) {
        return @{ Set = $null; Warn = "Policy is Group membership ($Groups). A user share is IGNORED - add the user to one of those Entra groups, or re-run with -Everyone." }
    }
    @{ Set = $null; Warn = $null }
}

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

function Read-RequiredValue {
    param([string] $Prompt, [string] $Value)
    while ([string]::IsNullOrWhiteSpace($Value)) { $Value = (Read-Host $Prompt).Trim() }
    $Value.Trim()
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

try {
    Write-Stage 'Step 3 - Share and publish the agents'

    $modes = @()
    if ($UserEmail)       { $modes += '-UserEmail' }
    if ($RevokeUserEmail) { $modes += '-RevokeUserEmail' }
    if ($Everyone)        { $modes += '-Everyone' }
    if ($RevokeEveryone)  { $modes += '-RevokeEveryone' }
    if ($modes.Count -gt 1) { throw "Pass only one grant at a time, got: $($modes -join ', ')" }

    $OrgUrl = (Read-RequiredValue 'Target Dataverse org URL (https://org....crm.dynamics.com)' (Get-Fallback $OrgUrl 'OrgUrl')).TrimEnd('/')
    if ($OrgUrl -notmatch '^https://') { throw "-OrgUrl must be an https org URL, got: $OrgUrl" }

    if (-not $Agent -or $Agent.Count -eq 0) {
        if ($State.Agents) { $Agent = @($State.Agents) }
        else {
            $Agent = @(Read-RequiredValue 'Agent schema names, comma separated (e.g. cr720_Agent1TestScript,cr720_Agent2UITesting)' $null)
        }
    }
    $Agent = @($Agent | ForEach-Object { $_ -split '[,\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $Agent.Count) { throw 'No agent schema names to act on.' }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) not found - install from https://aka.ms/azure-cli and run `az login`.'
    }
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

    function Invoke-AgentStage {
        param([string] $Bot)

        $row = (Invoke-Dv "bots?`$select=botid,name,accesscontrolpolicy,authorizedsecuritygroupids,publishedon&`$filter=schemaname eq '$Bot'").value
        if (-not $row)        { throw "No agent with schema name '$Bot' in $OrgUrl. Schema name, not display name." }
        if ($row.Count -gt 1) { throw "'$Bot' matched $($row.Count) agents." }

        Write-Info "$($row.name) [$Bot]"
        Write-Info "  policy      $($row.accesscontrolpolicy) $($PolicyName[[int]$row.accesscontrolpolicy])  $($row.authorizedsecuritygroupids)"
        Write-Info "  publishedon $($row.publishedon)"

        $target = @{ '@odata.id' = "bots($($row.botid))" }

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

        if ($Everyone) {
            Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{ accesscontrolpolicy = 0; authorizedsecuritygroupids = $null } | Out-Null
            Write-Ok "policy set to 0 $($PolicyName[0])"
        }

        if ($RevokeEveryone) {
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

        if ($UserEmail) {
            $user = Resolve-DvUser $UserEmail
            Write-Info "share with: $($user.fullname) <$($user.domainname)>"

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

            Invoke-Dv 'GrantAccess' -Method Post -Body @{
                Target          = $target
                PrincipalAccess = @{ Principal = @{ '@odata.id' = "systemusers($($user.systemuserid))" }; AccessMask = 'ReadAccess' }
            } | Out-Null
            Write-Ok '  share  ReadAccess granted on the agent'

            $fix = Get-SharePolicyFix -Policy ([int]$row.accesscontrolpolicy) -Groups $row.authorizedsecuritygroupids
            if ($fix.Warn) { Write-Warning $fix.Warn }
            if ($null -ne $fix.Set) {
                Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{ accesscontrolpolicy = $fix.Set } | Out-Null
                Write-Ok "  policy was 2 with no groups (nobody) - set to $($fix.Set) $($PolicyName[$fix.Set])"
            } else {
                Write-Info "  policy left at $($row.accesscontrolpolicy) $($PolicyName[[int]$row.accesscontrolpolicy])"
            }
        }

        if ($RevokeUserEmail) {
            $user = Resolve-DvUser $RevokeUserEmail
            Write-Info "revoke: $($user.fullname) <$($user.domainname)>"

            Invoke-Dv 'RevokeAccess' -Method Post -Body @{
                Target  = $target
                Revokee = @{ '@odata.id' = "systemusers($($user.systemuserid))" }
            } | Out-Null
            $still = Get-SharedPrincipals $target | Where-Object { $_.Principal.ownerid -eq $user.systemuserid }
            if ($still) { throw "RevokeAccess returned success but the share is still there: $($still.AccessMask)" }
            Write-Ok '  share  revoked on the agent'

            $fix = Get-RevokePolicyFix -Policy ([int]$row.accesscontrolpolicy) -Groups $row.authorizedsecuritygroupids
            if ($fix.Warn) { Write-Warning $fix.Warn }
            if ($null -ne $fix.Set) {
                Invoke-Dv "bots($($row.botid))" -Method Patch -Body @{ accesscontrolpolicy = $fix.Set } | Out-Null
                Write-Ok "  policy narrowed to $($fix.Set) $($PolicyName[$fix.Set])"
            } else {
                Write-Info "  policy left at $($row.accesscontrolpolicy) $($PolicyName[[int]$row.accesscontrolpolicy])"
            }

            Write-Info '  role   left as is. Environment Maker governs the whole environment, not this agent.'
        }

        $after = Invoke-Dv "bots($($row.botid))?`$select=accesscontrolpolicy,authorizedsecuritygroupids"
        Write-Info "now: policy=$($after.accesscontrolpolicy) $($PolicyName[[int]$after.accesscontrolpolicy]) $($after.authorizedsecuritygroupids)"

        if ($NoPublish) {
            Write-Warning "NOT published (-NoPublish). Nothing above reaches the runtime until you run: pac copilot publish --environment $OrgUrl --bot $Bot"
            return
        }

        $pac = Resolve-Pac
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
        Write-Host "    Failed: $($failed -join ', ')" -ForegroundColor Red
        exit 1
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
