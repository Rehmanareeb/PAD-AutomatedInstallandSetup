# Potential Issues

Everything in this pipeline that rests on something Microsoft has not documented,
or on a workaround for behaviour that is documented and wrong. If a deployment
that used to work suddenly stops, the cause is almost certainly on this page.

Nothing here is a bug report against our own code. These are the places where the
code is correct *today* because of how the platform behaves *today*, with no
contract saying it will keep behaving that way.

**Severity**

| | Meaning |
|---|---|
| 🔴 | Undocumented API or column. Microsoft can change it without notice and without a deprecation path. |
| 🟠 | Documented behaviour that is wrong, inconsistent, or silently lossy — we work around it. |
| 🟡 | Heuristic or format assumption. Correct for this solution / this CLI version; brittle to reformatting. |

**How the scripts are organised.** `Run-HandOver.ps1` contains all three stages
merged; `Prepare-Sol.ps1`, `Machine-and-Cua.ps1` and `Share-Agents.ps1` are the
same logic split up. An issue listed under a stage script applies to
`Run-HandOver.ps1` too.

---

## Cross-cutting

These bite in every script.

### 🟠 `pac.cmd` does not propagate exit codes

`pac` on Windows is a `.cmd` shim. A failed `pac solution pack`, `import` or
`publish` can still leave `$LASTEXITCODE` at 0, so a run carries on and "imports"
a file that was never written.

*How we handle it:* never trust the exit code alone. Prove the outcome instead —
the zip exists after a pack, `publishedon` moved after a publish, and the output
is scanned for `Error:`.

*If it breaks:* a stage reports success and the next one fails with something
unrelated. Check the pac output above the failure.

### 🟠 Windows PowerShell 5.1 writes a BOM where 7 does not

`Set-Content -Encoding utf8` means UTF-8 **with** a BOM on 5.1 and **without** on
7. `utf8NoBOM` does not exist on 5.1 at all. A BOM in any file inside the
solution makes the import fail with:

```
Flow clientdata is in invalid format. Details: "Unexpected character
encountered while parsing value: ∩╛┐. Path '', line 0, position 0."
```

— which is the bytes `EF BB BF` rendered in a non-UTF8 console.

*How we handle it:* every file rewritten between unpack and pack goes through
`[System.IO.File]::WriteAllText` with `New-Object System.Text.UTF8Encoding $false`.
XML goes through an `XmlWriter` with the same encoding — **not** `$xml.Save(path)`,
which emits a BOM, and emphatically not `$xml.Save(StringWriter)`, which stamps
`encoding="utf-16"` into the declaration and makes pac fail with *"There is no
Unicode byte order mark. Cannot switch to Unicode."*

*If it breaks:* the import fails on clientdata format. Check what last touched
the file.

### 🟡 PowerShell traps that have already cost real debugging time

| Trap | What actually happens |
|---|---|
| `$null += 'a'` then `+= 'b'` | Gives the **string** `'ab'`, not a two-element array. `.Count` is 1, so a mutual-exclusion guard built that way never fires. Cost a run that applied two opposite modes and published. Every accumulator here starts as `@()`. |
| `.Trim()` on an empty pipeline | A pipeline matching nothing yields *no output*, and calling a method on it throws *"You cannot call a method on a null-valued expression"*. This is the crash that used to stop machine registration. |
| `[string]$null` | Returns `$null` on PowerShell 7, not `''`. Casting is **not** a safe way to make an empty result string-like. Check `.Count` on a forced array instead. |
| `$args`, `$matches` | Automatic variables. Assigning to them inside a function works but shadows the real one. Renamed to `$azArgs` / `$envMatches` wherever the originals used them. |
| `"$id?api-version=..."` | `?` is a legal character in a PowerShell variable name, so this reads as the variable `$id?api` — empty — and the API rejects it with `InvalidApiVersion`. Braces (`${id}`) are load-bearing. |

### 🟠 There are now two copies of this logic

`Run-HandOver.ps1` was assembled from the three stage scripts, and all four were
ported from the originals in `Current_Scripts`. A fix in one copy does not reach
the others. `context.md` records the same trade-off for `Provision-CuaMachine.ps1`.

*If it breaks:* a bug you already fixed reappears. Fix it in every copy, or delete
the three stage scripts — `Run-HandOver.ps1 -OnlyPrepare` / `-OnlyMachine` /
`-OnlyShare` covers everything they do.

---

## Script 1 — `Prepare-Sol.ps1` (stage 1, solution preparation)

### 🔴 The `AllowedEnvironments` secret tag

Power Platform decides whether an environment may resolve a Key Vault secret by
reading a **tag** on the secret named `AllowedEnvironments`. The tag name, its
comma-separated format, and the fact that it contains *environment* ids are not
documented anywhere we can point to.

**This has already caused one failure.** The tenant id was being written into the
tag instead of the environment id. The vault is created, the tag is set,
everything reports success — and then the environment variable fails to resolve at
run time, because no environment in the list matches the one asking. Nothing in
the Azure or Power Platform error text points at the tag.

*How we handle it:* the tag now defaults to `-EnvironmentId`, every entry is
validated as a GUID, and the tenant id appearing in the list is a hard error with
an explanation.

*If it breaks:* agents fail at run time with a credential error while the vault
looks perfectly configured. Check the tag on the secret in the portal.

### 🟠 Key Vault RBAC is eventually consistent, with no ready signal

A freshly created vault accepts a role assignment and then rejects secret writes
for anything up to a couple of minutes. There is no documented way to ask whether
the assignment has propagated.

*How we handle it:* up to 12 attempts, 10 seconds apart, then a clear failure that
says RBAC propagation is the likely cause.

*If it breaks:* secret writes fail on a brand-new vault. Re-running usually
succeeds.

### 🟡 The Copilot Studio service principal is found by display name

The service principal that must read the secret is looked up as
`Microsoft Copilot Studio Service`, falling back to the legacy
`Power Virtual Agents Service`. Microsoft has renamed it once already.

*If it breaks:* vault creation fails with *"neither … was found in this tenant"*.
Add the new display name to the fallback list.

### 🔴 Hand-editing the unpacked solution

`pac solution unpack` / `pack` is supported. **What is inside the unpacked folder
is not a documented format.** We rewrite:

- the flow definition JSON (`Workflows\Save-Generated-CSV-To-SharePoint-*.json`)
- the two agent tool `data` files under `botcomponents\`
- `environmentvariabledefinitions\*\environmentvariabledefinition.xml`
- `Other\Solution.xml`
- `Assets\botcomponent_environmentvariabledefinitionset.xml`
- `Assets\botcomponent_dvtablesearchset.xml`

Any change to how Copilot Studio serialises a solution can break these silently —
the pack still succeeds, and the agent misbehaves at run time.

### 🟡 The agent tool `data` file is parsed by line, not by grammar

`Set-ToolInput` scans for a line `propertyName: <prop>` and then rewrites the
`value:` line within the next three lines. It is a heuristic over a YAML-ish
format with no published schema.

*If it breaks:* the script warns *"could not find '<prop>' input in <tool> - left
unchanged"* and the agent points at the wrong site or org. **The warning is easy
to miss** — it does not stop the run.

### 🟡 The SharePoint site value is found by string sniffing

A flow action's `dataset` is retargeted only if the current value looks like
`*sharepoint.com*` or `@parameters(*`. A site URL in another shape is skipped.

*If it breaks:* `throw "No SharePoint dataset values found"` — which at least
fails loudly.

### 🔴 A component must be registered in `RootComponents` or the import ignores it

Writing `environmentvariabledefinition.xml` into the folder is **not enough**. If
the component is not also listed in `Other\Solution.xml` under `<RootComponents>`,
it is carried in the zip and then silently ignored by the import. Type `380` is
Environment Variable Definition.

*How we handle it:* the `<RootComponent type="380" …/>` line is injected by regex
into the manifest.

*If it breaks:* the import succeeds and the environment variable simply is not
there.

### 🟠 `pac solution create-settings` writes a file its own import rejects

`create-settings` emits `"Value": ""` for every environment variable, and then
`solution import --settings-file` fails with *"Environment variable value can't be
an empty string"*. An entry that is simply **absent** is fine — the value baked
into the solution is used.

*How we handle it:* blank-valued entries are dropped before the file is written.

### 🟡 `pac connection list` is parsed by column position

Output is a fixed-width table with no machine-readable option. We take token 0 as
the id, token −2 as the connector path, token −1 as the status, and everything
between as the display name (names contain spaces).

*If it breaks:* connections are not found, or the wrong one is matched. Covered by
`-SelfTest`, which parses a captured sample.

### 🔴 The SharePoint connection consent flow is the portal's internal one

SharePoint Online publishes no service-principal parameter set — one `token` of
type `oauthSetting` with capability `cloud`, and username/password only under
capability `gateway`, which is on-premises SharePoint Server. So the first
connection in each environment needs a human.

What we automate is the portal's own sequence: create an unauthenticated
connection, `POST …/getConsentLink`, open the browser, then poll `properties.statuses`
until `Connected`. The portal's follow-up `confirmConsentCode` call is deliberately
skipped — signing in is what authenticates the connection.

*If it breaks:* the poll times out and leaves an orphan connection behind. The
error names it and tells you how to reuse or delete it.

### 🔴 The Dataverse connection's `ServicePrincipalOauth` parameter set

Creating a Dataverse connection app-only uses a parameter set named
`ServicePrincipalOauth` with keys `token`, `token:clientId`, `token:clientSecret`,
`token:TenantId`, `token:grantType`. These names are not documented.

**A bad secret still returns 201.** The failure appears only in
`properties.statuses`, so the connection is always read back.

### 🟠 `MissingEnvironmentFilter`

Every Power Apps connection call needs
`&%24filter=environment eq '<environmentId>'` appended or it fails. Not obvious
from the API surface.

### 🟠 Malformed Key Vault secret references fail uninformatively

Dataverse rejects a secret-type environment variable whose value is not a valid
secret reference with *"This variable didn't save properly"* — with no indication
of which variable or why.

*How we handle it:* the reference is validated against an anchored regex **before**
anything is unpacked, so the failure names the value.

### 🟡 Solution-internal names are assumptions

The flow filename pattern, both agent tool schema patterns, and the environment
variable schema names (`cre44_*`) are parameters with this solution's values as
defaults. They are properties of the package, not of an environment — but if the
solution is rebuilt with a different publisher prefix or renamed components, these
must change too.

### 🟡 Orphaned app-module search config is removed as an import fix

`dvtablesearchs` entries pointing at an app module the package does not ship will
fail the import. We delete them, and the matching `dvtablesearchentities`, before
packing. The reason this is needed is not documented.

---

## Script 2 — `Machine-and-Cua.ps1` (stage 2, machine and CUA)

### 🔴 `usagetype` on `flowmachinegroups`

"Enable for computer use" is not a machine setting. It is the `usagetype` column
on the machine's **group**: `1` = computer use, `0` = default desktop flows. That
column is **absent from Microsoft's published schema reference**. It works today
over the supported Dataverse Web API.

Two consequences:

- The flag applies to **every machine in the group**, not just this one.
- We deliberately fail *soft* here — a failure warns and points at the portal
  toggle rather than stopping the deployment.

### 🔴 Machine registration cannot use a token, and its identity is local

`PAD.MachineRegistration.Silent.exe` accepts `-username`, or `-applicationid` with
`-clientsecret` / `-certificatethumbprint`. That is the entire list. There is no
`-accesstoken`, and adding one would not help: registration provisions a **local
machine identity** and an Azure Relay connection held by `UIFlowService`, not a
row you can POST.

It signs in with its own client id into its own MSAL cache at
`%LOCALAPPDATA%\Microsoft\Power Automate Desktop\Cache\MSI\msalcache.bin3` — a
different cache from the Azure CLI's, which is why the two cannot be shared.

The client secret is piped over **stdin**, so it never appears in the process list.

### 🔴 Registration state is read from HKLM

`HKLM:\SOFTWARE\Microsoft\Power Automate Desktop\Registration` (and the
`WOW6432Node` variant) is an implementation detail, not an API. We read
`RegistrationState`, `MachineId`, `GroupIds`, `OrgUri` and `TenantId` from it.

**`GroupIds` can be empty or missing** on a partial registration, and on a VM
cloned from an image that was already registered. That is what used to crash the
original `Setup_PAD_Final.ps1:302`. It is now checked before use, and falls back to
a Dataverse lookup.

### 🟠 Do not clone the VM after registration

The registration record survives cloning; the machine identity does not. The clone
carries a registration pointing at a machine it is not, and shows up as a machine
that registers and then never comes online. `-Force` re-registers from scratch,
which **breaks existing connections to that machine**.

### 🔴 Creating a Computer Use connection cannot be app-only

Authorisation comes from the connectivity service, not Dataverse, and only an
identity the connection is shared with may create it. These connections are
created with `allowSharing = false`, so a service principal can never hold one.

Proven 2026-08-25: the app registration fails with **code 10006** while holding
System Administrator. No Dataverse role changes this. Expect one interactive
sign-in per machine.

### 🔴 The `azureRelay` connection parameter set

The connection carries a parameter set named `azureRelay` with `targetId`,
`username`, `password`, `environment`, `xrmInstanceUri` and `connectionType`.
Undocumented.

`targetId` is the machine **group** id, not the machine id — and the PUT response
is not documented to echo the parameter set, so the connection is always read back
to confirm `targetId` took.

### 🔴 The connection reference naming convention

The Dataverse `connectionreferences` row must be named
`<botComponentSchema>.shared_computeroperator.<connectionId>`. The platform relies
on this shape; nothing documents it.

### 🔴 The agent's machine binding lives inside a text blob

Agent 2's Computer Use action stores its binding as a `connectionReference:` line
inside the botcomponent's `data` field — a YAML-ish blob with no schema. We locate
and rewrite that line with a regex.

The action is also linked to the row through the `botcomponent_connectionreference`
navigation property, which is likewise undocumented.

### 🟠 `MSCRM.SolutionUniqueName` is required, or the publish is incomplete

Without that header the connection reference row lands in the **Default** solution
only. The agent then publishes a package that does not contain it, and the runtime
reports `SystemError` on every message.

*How we handle it:* the solution is read off the action itself rather than
hardcoded, and four facts are verified before any publish — the action's line, a
row answering to that name, the row's `connectionid`, and the row's solution
membership.

### 🔴 Step 4.4 — the entire Copilot Studio authentication surface

Copilot Studio publishes **no supported API** for setting an agent's
authentication. Everything in step 4.4 is internal:

| What | Why it is fragile |
|---|---|
| `…/api/botmanagement/v1/channels/authentication/connections/configuration` | Internal endpoint, no versioning guarantee. |
| `…/api/botauthoring/v1/environments/{env}/bots/{bot}/auth/authorization` | Same. |
| `x-cci-botid`, `x-cci-cdsbotid`, `x-cci-bapenvironmentid`, `x-cci-organizationid`, `x-cci-tenantid`, `x-cci-routing-botid` | Headers the web UI sends. Not a contract. |
| The Copilot service principal | Found by trying four display names, then trying each SPN as both `--resource` and `--scope` until a token comes back. |
| Delegated-token requirement | The gateway rejects app-only tokens. We decode the JWT and check `tid` matches and `idtyp != 'app'`. |
| The PVA gateway URL | Read from BAP `properties.runtimeEndpoints['microsoft.PowerVirtualAgents']`, falling back to building `https://powervamg.<cluster.uriSuffix>.powerapps.com`. |
| The internal routing bot id | May not be needed at all. If it is, it is found by scraping GUIDs out of the bot record and six candidate metadata endpoints, then validating each against the configuration endpoint. |

*How we handle it:* nothing is written until every piece of discovery has
succeeded, so a failure leaves the agent's authentication exactly as it was, and
the diagnostics on failure are deliberately verbose. `-SkipManualAuth` skips the
step; the designer equivalent is *Settings → Security → Authentication →
Authenticate manually*.

**This is the single most likely thing on this page to break.**

### 🟠 A partial `authenticationConnection` is returned when none exists

Some environments return a stub object with an empty `name` or `settingId` even
when no usable connection has been created. Treating that as an update and issuing
a `PUT` fails. It has to be treated as a create.

### 🟠 Changing the authentication mode can discard connections

Switching an agent **off** Custom Entra is known to drop the `connectionName` its
config carried. Setting it *to* Custom Entra should not — but that is an
assumption, so the CUA binding is re-verified immediately after step 4.4.

*If it breaks:* you get an explicit verification failure instead of an agent that
publishes cleanly and then cannot reach its machine.

---

## Script 3 — `Share-Agents.ps1` (stage 3, share and publish)

### 🔴 `accesscontrolpolicy` values were measured, not documented

| Value | Meaning |
|---|---|
| 0 | Any — everyone in the organisation |
| 1 | Copilot readers — only principals the row is shared with |
| 2 | Group membership — members of `authorizedsecuritygroupids` only |
| 3 | Any (multi-tenant) |

**Policy 2 with an empty group list means NOBODY**, and it ignores row shares
entirely. That is a state the portal's own org-wide share has been seen to leave
behind, and it is invisible unless you look at the column.

### 🔴 Which roles carry `prvReadbot` was measured

Chatting with an agent needs a security role carrying `prvReadbot`. Measured in
this org: Environment Maker, Bot Author, Bot Viewer and Agent Viewer carry it at
User depth. **Basic User and Microsoft Copilot User do not.**

We check the user's existing roles for the privilege via
`RetrieveRolePrivilegesRole` and only assign Environment Maker when none of them
carries it — that role is environment-wide and worth not handing out by reflex.

### 🟠 Three separate things gate access

Missing any one gives the same unhelpful message — *"You don't have access to talk
to this bot, contact the owner"*:

1. a role carrying `prvReadbot`
2. an access control policy that admits the user
3. a publish

### 🟠 Revoking a share does nothing while the policy is Any

If the policy is 0 or 3, everyone can chat regardless of row shares, so a revoke
changes nothing. We narrow the policy to 1 — which **cuts off every other user who
is not individually shared**. The script warns before doing it.

### 🟠 `pac copilot publish` and the missing exit code

`pac` has been seen to crash with `System.ArgumentException` on a freshly imported
agent that has never been published, and it does not propagate exit codes.

*How we handle it:* publish by the agent's **GUID** rather than its schema name
(skips a name lookup), scan the output for `non-recoverable error`, and treat
`publishedon` moving as the only honest proof of a publish.

### 🟡 A live conversation keeps the old configuration

An open chat session keeps working against the configuration it started with until
it idles out — about 30 minutes. End-to-end validation must use a **fresh**
session, or you will be testing the previous deployment.

---

## Script 4 — `Run-HandOver.ps1` (all three stages merged)

Everything above applies. These are specific to the merged file.

### 🟠 It was assembled, not retyped

The stage bodies were extracted from the three stage scripts programmatically, so
they are byte-identical to the versions that were checked. Two consequences:

- **The transplanted bodies are not re-indented.** They contain here-strings whose
  terminator must sit at column 0. Re-indenting them breaks parsing — this already
  happened once during the merge.
- **The share stage is wrapped in a function on purpose.** It defines its own
  `Invoke-Dv` and `Resolve-Pac` inside its `try` block. Nesting them is what stops
  those overriding the machine stage's versions at script scope. Flattening that
  function would break stage 2 in a way that only shows up at run time.

### 🟡 `$ClientId` / `$ClientSecret` mean different apps in different stages

The prepare stage uses those names for the **Graph** app; the machine stage uses
them for the **PAD registration** app. The orchestrator aliases them per stage from
`-GraphClientSecret` and `-PadClientSecret`. Reordering the stage calls without
moving the aliases would hand the wrong secret to the wrong API.

### 🟡 Each stage's own input collection is a deliberate no-op

`Read-RequiredValue 'prompt' $Value` returns immediately when the value is already
set, which is what lets the orchestrator collect everything up front and the
transplanted bodies run unchanged. If a stage body is ever edited to prompt
unconditionally, the "no mid-run prompts" guarantee is gone.

---

## What has actually been tested

Be clear about this when handing over.

**Tested, with runnable checks** (`.\Run-HandOver.ps1 -SelfTest`):

- `pac connection list` output parsing
- Key Vault secret-reference validation
- the `AllowedEnvironments` tag rules, including rejecting the tenant id
- the access-policy share/revoke rules
- the `GroupIds` normalisation that used to crash registration

**Not tested against a tenant:** everything that touches Azure, Dataverse, the
Power Apps API or Copilot Studio. That is most of the code. It has been read
carefully and parse-checked on PowerShell 5.1 and 7, and not executed.

**Suggested first run:** stage 1 with `-SkipImport`, then stage 2 with
`-SkipManualAuth`, then add the remaining steps once each has been seen to work.
`-WhatIfStages` prints everything that would happen without touching anything.

---

## Housekeeping

- **`Agent2-ManualAuth-AUtomation.ps1` in `Current_Scripts` contains a live client
  secret in plaintext on line 8.** Nothing here uses that file, but the value
  should be rotated and replaced with `$env:AGENT2_CLIENT_SECRET`. GitHub push
  protection has already blocked one push over it.
- **`.md` files in this folder are not tracked.** The repo's `.gitignore` allows
  only `/Current_Scripts/*.ps1`. Add `!/Current_Scripts/HandOver-Scripts/*.md` if
  this document should ship with the scripts.
