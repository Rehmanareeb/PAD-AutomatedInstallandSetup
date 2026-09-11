# HandOver-Scripts

Four scripts that run the CUA deployment end to end. **Self-contained** — they
call nothing in `Current_Scripts`, so this folder can be handed over on its own.
The logic came from the originals; nothing in `Current_Scripts` was modified.

Every hard-coded tenant id, environment id, org URL, subscription, vault name,
agent name and credential from the originals is a parameter here. Anything
required and not passed is prompted for; secrets are read with `-AsSecureString`,
converted only at the moment of use, and never written to disk or placed on a
command line.

## Start here

**`Run-HandOver.ps1` is the whole deployment in one file.** It contains every
stage, collects every input once up front, and calls nothing else. On the VM, as
Administrator:

```powershell
.\Run-HandOver.ps1
```

It prompts for anything it still needs, then runs all three stages in order and
stops on the first failure, naming the stage and the command to resume from.

The three stage scripts are the same logic split up, for running one stage on its
own. `Run-HandOver.ps1 -OnlyPrepare` / `-SkipPrepare` / `-OnlyShare` does the same
thing, so they are optional.

## Run order

| # | Script | Flow step | Where it runs |
|---|--------|-----------|---------------|
| — | **`Run-HandOver.ps1`** | **all of it, one file** | on the VM, **as Administrator** |
| 1 | `Prepare-Sol.ps1` | 1 — solution preparation | in the VM |
| 2 | `Machine-and-Cua.ps1` | 3 and 4 — machine setup, CUA configuration | on the VM, **as Administrator** |
| 3 | `Share-Agents.ps1` | 5 — share and publish | anywhere with `az` + `pac` |

## The agent identifiers are built in

These ship with the solution and are the same in every environment, so they are
defaults and are never prompted for:

| Parameter | Value |
|---|---|
| `-Agent1SchemaName` | `cr720_Agent1TestScript` |
| `-Agent2SchemaName` | `cr720_Agent2UITesting` |
| `-Agent2CuaComponentSchema` | `cr720_Agent2UITesting.action.Computeruse-Computeruse` |
| `-Agent2DisplayName` | `Agent 2 UI Testing` |

Override them only if the solution itself changes.

Flow step 2 — provisioning the VM itself — happens before any of this and is not
scripted here.

**The order matters.** Each stage creates the object the next one binds to. Run
stage 3 before stage 2 and you publish an agent whose Computer Use tool has no
machine.

## What each script does

### 1. `Prepare-Sol.ps1`

| Sub-step | Work |
|---|---|
| 1.1 | Download the solution package over https, verify it really is a zip |
| 1.2 | Create the Key Vault, assign RBAC to you, Copilot Studio and Dataverse, store the F&O credentials as tagged secrets |
| 1.3 | Unpack, retarget the SharePoint site and Dataverse org across the flow and both agent tools, point the Fno environment variables at the vault, repack |
| 1.4 | Create the Dataverse and SharePoint connections, fill the deployment settings file, import with it |

**Gate:** the import must succeed. On success the environment's solutions are
listed so you can confirm yours landed.

Why the pack step sits between the vault and the connections:
`Set-SolutionConnections.ps1` reads the connection references out of a packed
solution, so the retargeted zip has to exist first. The import is done by
`Set-SolutionConnections.ps1` rather than `Flow-1.ps1` because only it can pass
`--settings-file` — without that the agent arrives with empty connection
references and its tools fail at run time.

### 2. `Machine-and-Cua.ps1`

| Sub-step | Work |
|---|---|
| 3.1 | Preflight (admin, edition, connectivity), install Power Automate silently, register the machine |
| 3.2 | Enable the machine **group** for computer use (`usagetype = 1`) |
| 3.3 | Create the Computer Use connection carrying the Windows credential, verify its `targetId` |
| 4.1–4.3 | Create or reuse the connection reference in the action's own solution, link it, repoint the action, verify all four facts |
| 4.4 | Set Agent 2's authentication to manual (Custom Entra), then **re-verify the binding** |

**Gate:** the machine must be registered and have a machine group before the
connection is created, and the connection must exist before the agent binding.

Agent 2 is **not** published here by default — that is stage 3, so a
half-configured agent never reaches the runtime. Pass `-PublishNow` to override.

Step 4.4 talks to undocumented Copilot Studio endpoints — see Known limitations.
The binding is re-verified afterwards because changing an agent's authentication
mode can discard its connections.

### 3. `Share-Agents.ps1`

For each agent in order: report current access, apply the grant, then publish.
Publish last, because nothing reaches the runtime until a publish. With no grant
switch it reports and changes nothing — the safe way to check where a deployment
got to.

Chatting with an agent needs **three** things, and missing any one gives "You
don't have access to talk to this bot": a role carrying `prvReadbot`, an access
policy that allows the user, and a publish. `-UserEmail` does all three.

### 4. `Run-HandOver.ps1` — the single-file version

Contains all three stages. Collects every input **up front**, so nothing stops
halfway through to ask a question, then runs 1 → 2 → 3. Stops on the first
failure, names the stage, and prints the command to resume from there.

`-WhatIfStages` prints the stages and every collected value, then stops without
touching anything — worth running before a long command line.

## Examples

Full deployment:

```powershell
.\Run-HandOver.ps1 -OrgUrl https://org35fd7a12.crm.dynamics.com `
                   -EnvironmentId 20bbbb76-91c1-efde-bf32-8a5468336104 `
                   -TenantId edda99bb-bab6-4c4c-8aa1-4b99e8e09c1b `
                   -SolutionUrl https://files.catbox.moe/abc123.zip `
                   -SharePointUrl https://contoso.sharepoint.com/sites/AICOE `
                   -SubscriptionId 0c33fa37-4fa1-466d-a891-46af9e2f6e44 `
                   -ResourceGroupName rg-cua-uat -Location 'East US' `
                   -KeyVaultName kv-cua-uat-01 `
                   -Everyone
```

The agents are built in, and the Key Vault's `AllowedEnvironments` secret tag
defaults to `-EnvironmentId`, so neither has to be passed.

Check a command line before committing to it:

```powershell
.\Run-HandOver.ps1 -SkipPrepare -WhatIfStages
```

Resume after a failed stage 2:

```powershell
.\Run-HandOver.ps1 -SkipPrepare
```

Stages standalone:

```powershell
.\Prepare-Sol.ps1 -SolutionPath .\CUAExecutionValidator.zip -SkipKeyVault -SkipImport
```

```powershell
.\Machine-and-Cua.ps1 -SkipRegistration -ConnectionName CUA-UAT-01-CUA
```

```powershell
.\Share-Agents.ps1 -Agent cr720_Agent1TestScript,cr720_Agent2UITesting
```

Every script takes `-Help`, and `Get-Help .\Prepare-Sol.ps1 -Full` works.

## Prerequisites

| Tool | Needed by | Note |
|---|---|---|
| `az login` | stages 1, 2, 3 | Key Vault, connections, Dataverse calls |
| `pac auth` profile | stages 1, 3 | unpack, pack, import, publish |
| Administrator | stage 2 | machine registration only |
| Power Automate machine-registration app | stage 2 | Flow Service permissions with admin consent, plus an application user in the target environment |

`az` and `pac` must be signed in to the **same tenant** as the target
environment.

## Authentication — why there is no single credential

Three operations, three different answers. This is the constraint the whole
design works around:

- **Machine registration cannot use a token.** `PAD.MachineRegistration.Silent.exe`
  takes a username, or an app id with a client secret. It provisions a local
  machine identity, not a row you can POST.
- **Creating the Computer Use connection cannot be app-only.** Authorisation
  comes from the connectivity service, and these connections are created with
  sharing disabled, so a service principal fails with **code 10006** even holding
  System Administrator. Expect one interactive sign-in per machine.
- **The first SharePoint connection needs a person.** `shared_sharepointonline`
  publishes no service principal parameter set. Once one exists its id is
  reusable — pass `-SkipCreateSharePoint` with a `-Connection` pin on later runs.
- **Everything else** is an ordinary delegated call off `az login`.

## Running app-only

Most of the pipeline works signed in as a service principal:

```powershell
az login --service-principal -u <appId> -p <secret> --tenant <tenantId>
```
```powershell
pac auth create --applicationId <appId> --clientSecret <secret> --tenant <tenantId> --environment <orgUrl>
```

What that app needs:

| Kind | Grant | Scope | For |
|---|---|---|---|
| Azure RBAC | `Contributor` | subscription | resource group, vault, `az provider register` (subscription-scoped) |
| Azure RBAC | `Role Based Access Control Administrator` | the resource group | the four role assignments — Contributor cannot create them |
| Azure RBAC | `Key Vault Secrets Officer` | the resource group | write the F&O secrets (the vault does not exist yet) |
| Graph **application** | `Application.Read.All`, admin consent | tenant | `az ad sp show`, and the Copilot Studio / Dataverse SP lookups |
| Dataverse | application user, **System Administrator** | the environment | solution import, `usagetype`, connection references, `accesscontrolpolicy`, publish |

Register the provider once by hand and RG-scoped Contributor is enough — subscription
Contributor is only there for `az provider register`.

Pass `-EnvironmentId` when running app-only. Without it stage 1.4 looks the
environment up through `api.powerapps.com`, which is the one avoidable delegated
call in the pipeline.

## Where app-only does not work

Three steps refuse a service principal, and each one now fails **before** the
call rather than several requests later:

| Step | Why | What to do |
|---|---|---|
| First SharePoint connection (1.4) | `shared_sharepointonline` publishes no service principal parameter set | one human sign-in per environment. Afterwards `-SkipCreateSharePoint` with `-Connection shared_sharepointonline=<id>` |
| Computer Use connection (3.3) | created with sharing disabled, so the connectivity service answers **code 10006** | sign in as a person, or `-Interactive` for a device code. Once per machine |
| Agent authentication (4.4) | the Copilot gateway rejects a token whose `idtyp` is `app` | sign in as a person, or `-SkipManualAuth` and set it in the designer |

Not verified either way: the **Dataverse connection** PUT in stage 1.4, and
`pac copilot publish` under a service-principal profile. Both are left
unguarded — try them app-only and see. If the connection PUT is refused, create
it once by hand and pass `-SkipCreateDataverse -Connection shared_commondataserviceforapps=<id>`.

`pac connection list` under a service-principal profile may not see connections
owned by a person — which the SharePoint one will be. Pin it with `-Connection`
rather than relying on the listing.

So the realistic floor is **two browser sign-ins per environment**, not zero.

## `handover-state.json`

Each stage writes the non-secret answers it collected — org URL, environment id,
machine name, connection name, agent names — to `handover-state.json` in this
folder. The next stage reads them as defaults, so you are asked once, not three
times. **No secret is ever written to it.** Delete the file to start clean.

## Where the logic came from

All four scripts are self-contained. The originals were read, not called:

| This script | Logic ported from |
|---|---|
| `Prepare-Sol.ps1` | `Create-KeyVault.ps1`, `Flow-1.ps1` (solution stage), `Set-SolutionConnections.ps1` |
| `Machine-and-Cua.ps1` | `Setup_PAD_Final.ps1`, `CreateCUA-Connection.ps1`, `Switch-CUA-Con.ps1`, `Agent2-ManualAuth-AUtomation.ps1` |
| `Share-Agents.ps1` | `Share-Agent.ps1` |
| `Run-HandOver.ps1` | all three of the above, merged |

The cost of that is real, and it is now paid **twice**: a fix in an original does
not reach these scripts, and a fix in a stage script does not reach
`Run-HandOver.ps1`. `context.md` records the same trade-off for
`Provision-CuaMachine.ps1`. If a bug is found in one copy, fix it in all of them
— or delete the three stage scripts, since `Run-HandOver.ps1 -OnlyPrepare` /
`-OnlyMachine` / `-OnlyShare` covers everything they do.

`Run-HandOver.ps1` was assembled from the stage scripts programmatically rather
than retyped, so the bodies are byte-identical to the versions they came from.
One detail worth knowing if you edit it: the share stage is wrapped in a function
specifically because it defines its own `Invoke-Dv` and `Resolve-Pac`, and
nesting them is what stops those overriding the machine stage's versions.

One bug was fixed on the way in — `Setup_PAD_Final.ps1:302` calls `.Trim()` on a
pipeline that matched nothing, which crashes with "You cannot call a method on a
null-valued expression" whenever the registry has no `GroupIds` value. The
version here checks the count first, and falls back to a Dataverse lookup.

## Read this before handing over

**[Potential Issues.md](./Potential%20Issues.md)** lists everything in this
pipeline that rests on an undocumented API, an undocumented column, or a
workaround for platform behaviour that is wrong — broken down per script. If a
deployment that used to work stops working, the cause is almost certainly on that
page.

## Self-tests

Two scripts carry checks that need no tenant:

```powershell
.\Prepare-Sol.ps1 -SelfTest    # pac output parsing, Key Vault secret references
.\Share-Agents.ps1 -SelfTest   # the access-policy rules
```

```powershell
.\Test-AppOnly.ps1             # service principal vs user branching, and that the three human-only steps are guarded
```

## Known limitations

- **Step 4.4 talks to undocumented endpoints.** Copilot Studio publishes no
  supported API for setting an agent's authentication, so it discovers the
  Copilot service principal, environment, PVA gateway and internal routing bot
  id at run time, probing candidate routes and validating each answer. It is the
  part most likely to break when Microsoft changes something. Nothing is written
  until every piece of discovery succeeds, so a failure leaves the agent's
  authentication as it was. `-SkipManualAuth` skips it; the designer equivalent
  is *Settings → Security → Authentication → Authenticate manually*.
- **`Agent2-ManualAuth-AUtomation.ps1` contains a live client secret in
  plaintext** (line 8). Nothing here uses that file, but the value should be
  rotated and replaced with `$env:AGENT2_CLIENT_SECRET`.
- **Only the pure helpers are tested.** Everything that touches Azure, Dataverse
  or Copilot Studio has been read carefully and parse-checked, but not executed
  against a tenant.
- **Secrets are prompted at collection time, not read from a vault.** For an
  unattended run, supply them as `SecureString` parameters from your own secret
  store.
- **Step 5.4, the end-to-end validation test, is a manual checklist.**
  `Share-Agents.ps1` prints it; nothing drives a real conversation through
  Agent 1 → Agent 2 → the machine.
- **The solution-internal names** — the Fno / SharePoint / Dataverse environment
  variable schema names, the CSV flow filename pattern, and the two agent tool
  patterns — are parameters with the current values as defaults. They are
  properties of the solution package, so they only change if the solution does.
