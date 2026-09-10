<#
.SYNOPSIS
  Hand-over step 3: share the agents and publish them. Flow step 5.

.DESCRIPTION
  Runs Share-Agent.ps1 once per agent. For each one it grants access and then
  publishes, in that order, because nothing reaches the runtime until a publish.

      5.1  share and publish Agent 1
      5.2  share and publish Agent 2
      5.3  report the resulting access for both
      5.4  print the end-to-end validation checklist

  ACCESS CONTROL, the part that is easy to get wrong. Chatting with an agent
  needs THREE things, and missing any one gives the user "You don't have access
  to talk to this bot, contact the owner":

    1. A security role carrying prvReadbot. Environment Maker, Bot Author, Bot
       Viewer and Agent Viewer all carry it; Basic User and Microsoft Copilot
       User do NOT. Share-Agent.ps1 assigns Environment Maker only when none of
       the user's existing roles carries the privilege.
    2. The agent's access control policy allowing them.
    3. A publish.

  Share-Agent.ps1 does all three. This script only decides which agents, in what
  order, and with which grant.

  Run this AFTER Machine-and-Cua.ps1. Publishing before the Computer Use binding
  exists ships an agent whose tool has no machine.

  With neither -Everyone nor -UserEmail nor -RevokeUserEmail, this reports the
  current policy and shares for each agent and changes nothing. That is the safe
  way to check where a deployment got to.

  REQUIRES: az login for the Dataverse calls, and a pac auth profile in the same
  tenant for the publish.

.PARAMETER SourceRoot
  Folder holding the original scripts. Defaults to this script's parent, i.e.
  Current_Scripts.

.PARAMETER OrgUrl
  Target Dataverse org URL, e.g. https://org35fd7a12.crm.dynamics.com

.PARAMETER Agent
  Schema names of the agents to share and publish, in order. Schema names, not
  display names. Prompted for if omitted; comma or space separated at the prompt.

.PARAMETER Everyone
  Share with everyone in the organisation - sets the access control policy to
  Any. This is what the flow's "share both agents with the organization" step
  does.

.PARAMETER UserEmail
  Share with one user instead, by email.

.PARAMETER RevokeUserEmail
  Revoke one user. NARROWING AN ORG-WIDE POLICY CUTS OFF EVERY OTHER USER who is
  not individually shared - Share-Agent.ps1 warns before it does so.

.PARAMETER RevokeEveryone
  Withdraw the org-wide grant. Individual shares survive.

.PARAMETER NoPublish
  Write the sharing change and stop. Nothing reaches the runtime until a publish,
  so use this only when you intend to publish separately.

.PARAMETER ContinueOnError
  Carry on to the next agent if one fails, instead of stopping. The failure is
  still reported and the script exits non-zero.

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
  .\Share-Agents.ps1 -Help
#>
[CmdletBinding()]
param(
    [switch] $Help,

    [ValidateNotNullOrEmpty()]
    [string] $SourceRoot = (Split-Path -Parent $PSScriptRoot),

    [string]   $OrgUrl,
    [string[]] $Agent,

    # --- grant, at most one ---------------------------------------------------
    [switch] $Everyone,
    [string] $UserEmail,
    [string] $RevokeUserEmail,
    [switch] $RevokeEveryone,

    [switch] $NoPublish,
    [switch] $ContinueOnError
)

$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; return }

function Write-Stage { param([string] $m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Info  { param([string] $m) Write-Host "    $m" }

function Read-RequiredValue {
    param([string] $Prompt, [string] $Value)
    while ([string]::IsNullOrWhiteSpace($Value)) { $Value = (Read-Host $Prompt).Trim() }
    $Value
}

function Get-Source {
    param([string] $Name)
    $p = Join-Path $SourceRoot $Name
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "Missing source script: $p`nPass -SourceRoot pointing at the folder holding the Current_Scripts files."
    }
    $p
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

    $share = Get-Source 'Share-Agent.ps1'

    # Start from a real array. A pipeline that yields nothing gives $null, and
    # $null += 'a' then += 'b' concatenates into ONE string whose .Count is 1, so
    # a guard built that way never fires and two modes both run.
    $modes = @()
    if ($Everyone)        { $modes += '-Everyone' }
    if ($UserEmail)       { $modes += '-UserEmail' }
    if ($RevokeUserEmail) { $modes += '-RevokeUserEmail' }
    if ($RevokeEveryone)  { $modes += '-RevokeEveryone' }
    if ($modes.Count -gt 1) {
        throw "Pass only one grant at a time, got: $($modes -join ', ')"
    }

    $OrgUrl = Read-RequiredValue 'Target Dataverse org URL (https://org....crm.dynamics.com)' (Get-Fallback $OrgUrl 'OrgUrl')
    $OrgUrl = $OrgUrl.Trim().TrimEnd('/')
    if ($OrgUrl -notmatch '^https://') { throw "-OrgUrl must be an https org URL, got: $OrgUrl" }

    # Accept 'a,b' and 'a b' as well as a real array, from the prompt or the flag.
    if (-not $Agent -or $Agent.Count -eq 0) {
        $cached = @()
        if ($State.Agents) { $cached = @($State.Agents) }
        elseif ($State.Agent2SchemaName) { $cached = @($State.Agent2SchemaName) }
        if ($cached.Count) {
            $Agent = $cached
        } else {
            $Agent = @((Read-RequiredValue 'Agent schema names, comma separated (e.g. cr720_Agent1TestScript,cr720_Agent2UITesting)' $null))
        }
    }
    $Agent = @($Agent | ForEach-Object { $_ -split '[,\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $Agent.Count) { throw 'No agent schema names to act on.' }

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
        $a = @{ OrgUrl = $OrgUrl; Bot = $bot }
        if ($Everyone)        { $a.Everyone        = $true }
        if ($UserEmail)       { $a.UserEmail       = $UserEmail }
        if ($RevokeUserEmail) { $a.RevokeUserEmail = $RevokeUserEmail }
        if ($RevokeEveryone)  { $a.RevokeEveryone  = $true }
        if ($NoPublish)       { $a.NoPublish       = $true }

        try {
            & $share @a
        }
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
