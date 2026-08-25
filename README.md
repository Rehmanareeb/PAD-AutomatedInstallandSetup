# Setup_PAD_Final.ps1 — unattended Power Automate machine provisioning

[Setup_PAD_Final.ps1](Setup_PAD_Final.ps1) takes a fresh Windows machine to "registered and
visible in Power Automate" in one pass: it installs Power Automate for desktop
and registers the machine to a Power Platform environment, with no interactive
sign-in and without ever launching the Power Automate GUI.

Authentication is by **Microsoft Entra app registration** — client ID, tenant ID
and a client secret. That is the only mode the script supports.

The tenant-side setup — an Azure app registration with Microsoft Flow Service
permissions, and that app added as an application user in the target environment
— is **performed by the client**, who provides the tenant ID, client ID, client
secret and environment ID. See
[One-time tenant setup](#one-time-tenant-setup--performed-by-the-client) for what
that involves.

---

## What the script does

1. **Preflight**
   - Administrator rights.
   - Rejects Windows Home editions — direct connectivity is not supported there.
   - Probes outbound HTTPS to `login.microsoftonline.com`,
     `gateway.prod.island.powerapps.com` and `go.microsoft.com`. A blocked
     endpoint otherwise shows up much later as a generic "error connecting to the
     Power Automate cloud services", so it is worth failing loudly up front.
   - Checks `PAD_SECRET` is set, *before* the download, so a missing secret
     fails in seconds rather than after a several-minute install.
2. **Download** — pulls the installer from the Microsoft FWLink
   (`linkid=2102613`) into `%TEMP%\pad-install`.
3. **Silent install** — `Setup.Microsoft.PowerAutomate.exe -Silent -Install
   -ACCEPTEULA`. Installs Power Automate for desktop, the machine-runtime app and
   the browser extensions. `-ACCEPTEULA` is mandatory for unattended runs.

   **Already installed?** Steps 2 and 3 are skipped entirely — no download, no
   installer run — and the script goes straight to registration. Detection is the
   presence of `PAD.MachineRegistration.Silent.exe` in the Power Automate install
   folder; the version found is printed. Pass `-Reinstall` to install over the
   top anyway. This makes the script safe to re-run on a machine that is already
   built, e.g. to move it to a different environment.
4. **Register — your choice.** The script asks whether to connect this machine to
   the environment:

   ```
   [1] Yes - register this machine now
   [2] No  - skip registration, continue to the browser extensions
   ```

   Choosing **2** skips registration entirely and goes straight to the extension
   step, so the machine is built but does not appear in Power Automate. Pass
   `-Register Yes` or `-Register No` to answer without prompting — unattended
   runs must do this, since there is nothing to answer the prompt.

   **Already registered?** Before asking anything, the script reads Power
   Automate's own registration record:

   ```
   HKLM:\SOFTWARE\WOW6432Node\Microsoft\Power Automate Desktop\Registration
     RegistrationState : Registered
     MachineId / GroupIds / OrgUri / TenantId
   ```

   If `RegistrationState` is `Registered`, **the prompt above is not shown at
   all** — registration is skipped, and the run goes straight to the
   computer-use check. `-Force` registers again anyway. This needs no
   credentials and no network, and it is authoritative for *this* box, which
   asking Dataverse by machine name is not.

   It also means `-OrgUrl` and `-TenantId` are read from `OrgUri`/`TenantId` in
   that key when you don't pass them, and `GroupIds` gives the machine group
   directly, so the computer-use step skips its lookup entirely.

   On **1**, it then asks for the details it needs — environment ID, tenant ID,
   application ID, and the client secret if `PAD_SECRET` is unset (masked input).
   Each is validated as a GUID on entry, and anything already passed on the
   command line is used without asking. **Nothing is asked for on choice 2**, so
   an install-and-extension run needs no parameters at all.

   Then it runs `PAD.MachineRegistration.Silent.exe -register -applicationid
   <app-id> -clientsecret -tenantid <tenant-id> …` (see [the underlying
   registration command](#the-underlying-registration-command)), then confirms
   the machine-runtime Windows service is running and starts it if not. This is
   what makes the machine appear in Power Automate: the runtime authenticates
   *outbound* and creates the `flowmachine` record in Dataverse. There is no
   agentless path.
5. **Enable for computer use — optional, `-EnableComputerUse`.** Normally a
   human has to open the portal and flip Machines → *machine* → Settings →
   Enable for computer use. With `-EnableComputerUse` and `-OrgUrl`, the script
   does it over the Dataverse Web API instead, using the same service principal
   it registered with.

   It is not a machine setting — it is the `usagetype` column on the machine's
   **group** (`1` = computer use, `0` = default desktop flows). The script finds
   the machine, reads `_flowmachinegroupid_value`, checks the group's current
   `usagetype`, and `PATCH`es only if needed:

   ```
   PATCH <OrgUrl>/api/data/v9.2/flowmachinegroups(<groupid>)
   { "usagetype": 1 }
   ```

   It then re-reads the value to confirm it took. Re-running reports *already
   enabled* and issues no PATCH.

   > ⚠️ **This applies to every machine in that group**, not just this one.
   >
   > ⚠️ `usagetype` is **not in Microsoft's published schema reference**. It uses
   > the supported Dataverse Web API and works today, but treat it as
   > undocumented — the step fails soft, so any error warns, prints the manual
   > portal fallback, and lets the run finish reporting registration success.
6. **Browser extensions** — adds the Power Automate extension ID to the
   `ExtensionInstallForcelist` machine policy for both browsers:

   | Browser | Policy key | Extension ID (v2.27+) |
   |---|---|---|
   | Chrome | `HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist` | `ljglajjnnkapghbckkcmodicjhacbfhk` |
   | Edge | `HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist` | `kagpabjoboikccfdghpdlaaopmgpgfdc` |

   The installer ships the extension, but a user can disable it; the policy makes
   the browser install it on next launch, enable it, and grey out the remove
   toggle. Edge is Chromium, so the mechanism is identical — only the key and ID
   differ, and the Edge entry carries an explicit add-ons-store update URL.
   Idempotent — an entry already listed is left alone, and unrelated entries are
   never overwritten. **Both browsers must be restarted** to pick it up; verify
   at `chrome://policy/` and `edge://policy/`. Skip with `-SkipChromeExtension`
   / `-SkipEdgeExtension`.

   > For PAD v2.26 or earlier the legacy IDs apply instead:
   > `gjgfobnenmnljakmhboildkafdkicala` (Chrome),
   > `njjljiblognghfjfpcdpdbpbfcmhgafg` (Edge).

The client secret is read from the `PAD_SECRET` environment variable and piped to
the registration tool over **stdin** — never passed as a command-line argument,
where it would be visible in the process list. `PAD_SECRET` is cleared after
registration.

> **Do not clone a VM after this script has run.** Microsoft's guidance is to
> keep the base image clean — the machine identity and registration break on
> clone. Run the script post-clone, on each machine.

---

## Prerequisites

- Windows 10/11 **Pro, Enterprise or Education**, or Windows Server. Not Home.
- Local Administrator on the machine.
- A Power Platform environment, and its **environment ID** (GUID). Find it in the
  Power Automate portal URL, or in
  [admin.powerplatform.com](https://admin.powerplatform.com) → **Environments** →
  select the environment → the ID is on the details pane.
- The [one-time tenant setup](#one-time-tenant-setup--performed-by-the-client)
  done **by the client**, and the four values handed over: tenant ID, client ID,
  client secret, environment ID.
- Appropriate Power Automate RPA licensing on the environment.
- Outbound HTTPS (443) to `*.dynamics.com`, `*.servicebus.windows.net`,
  `*.gateway.prod.island.powerapps.com` and `login.microsoftonline.com`.

---

## One-time tenant setup — performed by the client

**This section is not run by this script.** The client does it once per
environment and hands over four values, which are all `Setup_PAD_Final.ps1`
needs:

| Value | Where it comes from |
|---|---|
| **Tenant ID** | Entra app registration → Overview → Directory (tenant) ID |
| **Client ID** | Entra app registration → Overview → Application (client) ID |
| **Client secret** | Entra app registration → Certificates & secrets |
| **Environment ID** | Power Platform admin center → the environment's details pane |

The steps below are recorded so both sides agree on what has to exist before a
machine can register. Portal wording drifts, so treat the menu names as
approximate.

### 1. Azure app registration

1. Go to [portal.azure.com](https://portal.azure.com) → **Microsoft Entra ID** →
   **App registrations** → **New registration**.
2. Name it (e.g. `pad-machine-registration`), leave it **single tenant**, and skip
   the redirect URI. **Register**.
3. On the **Overview** page copy and keep:
   - **Application (client) ID**
   - **Directory (tenant) ID**
4. **API permissions** → **Add a permission** → **Microsoft Flow Service** →
   **Delegated permissions**, and tick **all the Flow permissions plus the user
   permission**:
   - `Activity.Read.All`
   - `Approvals.Manage.All`
   - `Approvals.Read.All`
   - `Flows.Manage.All`
   - `Flows.Read.All`
   - `User`

   → **Add permissions**.
5. **Grant admin consent for \<tenant\>** and confirm every row turns green.
   Requires a Privileged Role Administrator or Global Administrator.
6. **Certificates & secrets** → **New client secret** → set an expiry → **Add**.
   Copy the secret **Value** immediately — it is shown only once. This is what
   goes into `$env:PAD_SECRET`.

Steps 3 and 6 are the only place the client ID, tenant ID and secret are
visible. Record all three.

### 2. Register the app in the Power Platform admin center

An Entra app registration on its own is invisible to Dataverse. It needs an
**application user** in the environment machines are registered into.

1. Go to [admin.powerplatform.com](https://admin.powerplatform.com) →
   **Environments** → select the target environment.
2. **Settings** → **Users + permissions** → **Application users**.
3. **+ New app user**.
4. **+ Add an app** → search for the app registration by name or client ID →
   select it → **Add**.
5. Pick a **Business unit** (the root business unit is the normal choice).
6. **Security roles** → **Edit** → assign **Desktop Flows Machine Owner**, plus
   **Environment Maker** and **Basic User** if your roles do not already inherit
   them.
7. **Create**. The app user now appears in the Application users list.

While in the admin center, note the environment GUID from the environment's
details pane — that is `-EnvironmentId`. Also confirm the environment has the RPA
capacity the machine will consume.

That is the whole setup. There is no service account and no interactive sign-in:
the app registration *is* the identity, so nothing has to be excluded from MFA.

---

## How to run

Open PowerShell **as Administrator** in this folder. If scripts are blocked:

```bash
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Then, with no arguments — it asks whether to register, and only then for the
details it needs:

```bash
.\Setup_PAD_Final.ps1
```

To install and set the extension policy without registering at all:

```bash
.\Setup_PAD_Final.ps1 -Register No
```

Unattended, answering everything up front:

```bash
$env:PAD_SECRET = '<client secret>'
```

```bash
.\Setup_PAD_Final.ps1 -Register Yes -EnvironmentId '<env-guid>' -ApplicationId '<app-id>' -TenantId '<tenant-id>' -MachineName 'CUA-UAT-01'
```

End to end with no portal interaction at all, including computer use:

```bash
.\Setup_PAD_Final.ps1 -Register Yes -EnableComputerUse -OrgUrl 'https://<org>.crm.dynamics.com' -EnvironmentId '<env-guid>' -ApplicationId '<app-id>' -TenantId '<tenant-id>'
```

`-MachineName` is optional; it defaults to the computer name.

### Parameters

| Parameter | Notes |
|---|---|
| `-EnvironmentId` | Power Platform environment GUID. Asked for if registering and not supplied. |
| `-ApplicationId` | Application (client) ID of the app registration. Asked for if registering and not supplied. |
| `-TenantId` | Directory (tenant) ID. Asked for if registering and not supplied. |
| `-Register` | `Ask` (default, prompts), `Yes` (register without prompting), `No` (skip registration). Unattended runs must pass `Yes` or `No`. |
| `-EnableComputerUse` | After registering, enable the machine for computer use instead of toggling it in the portal. Applies to the whole machine group. Fails soft. |
| `-OrgUrl` | Dataverse org URL. A bare host (`orgc0ee9ebb.crm.dynamics.com`) is accepted and normalised. Needed for `-EnableComputerUse`; taken from the local registration when the machine is already registered, otherwise asked for. |
| `-MachineName` | Defaults to `$env:COMPUTERNAME`. |
| `-MachineDescription` | Free text shown in the portal. Defaults to `CUA`. |
| `-InstallerUrl` | Override the installer download link. |
| `-WorkDir` | Download folder. Default `%TEMP%\pad-install`. |
| `-SkipConnectivityCheck` | For proxies that block the probe but allow real traffic. |
| `-ChromeExtensionId` | Chrome extension ID. Defaults to `ljglajjnnkapghbckkcmodicjhacbfhk`. |
| `-EdgeExtensionId` | Edge extension ID. Defaults to `kagpabjoboikccfdghpdlaaopmgpgfdc`. |
| `-SkipChromeExtension` | Leave Chrome policy alone, e.g. the extension is already deployed by GPO. |
| `-SkipEdgeExtension` | Leave Edge policy alone. |
| `-Reinstall` | Install Power Automate again even if it is already present. Without it, an existing install is left alone and only the registration runs. |
| `-Force` | Override an existing machine registration. **This breaks existing connections to the machine.** Does not trigger a reinstall. |

The script exits `0` on success and `1` on failure.

### The underlying registration command

Everything the script does at step 4 is a call to Microsoft's silent registration
tool, installed with Power Automate at:

```
%ProgramFiles(x86)%\Power Automate Desktop\PAD.MachineRegistration.Silent.exe
```

The command it builds is:

```
PAD.MachineRegistration.Silent.exe -register -applicationid <app-id> -clientsecret -tenantid <tenant-id> -environmentid <env-id> -machinename <machine-name> -machinedescription CUA
```

Note that `-clientsecret` takes **no value on the command line** — the tool reads
the secret from stdin, which is why the script pipes `PAD_SECRET` in that way and
why the secret never lands in the process list.

`-force` is appended when the script is run with `-Force`. The script echoes the
exact argument list it used (secret omitted) before running it, which is the
first thing to check when a registration fails.

### After a successful run

The machine appears at **make.powerautomate.com → Machines**. Unless you passed
`-EnableComputerUse`, one step remains and must be done in the portal:

> Machines → *your machine* → **Settings** → **Enable for computer use** → Save

The closing summary tells you which applies — enabled, failed with the manual
fallback, or not attempted.

Readiness can be polled from Dataverse instead of the UI:

```
GET /api/data/v9.2/flowmachines?$filter=name eq 'CUA-UAT-01'
    &$select=name,statuscode,lastheartbeatdate,agentversion
```

Ready when `statuscode = 1` (Active) with a recent `lastheartbeatdate`.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `This script must run as Administrator` | Elevate the PowerShell session. |
| `Direct connectivity is not available on Windows … Home` | Unsupported edition. Use Pro/Enterprise/Server. |
| `… :443 UNREACHABLE` warning | Proxy/firewall blocking the Power Automate endpoints. Fix the allow-list, or pass `-SkipConnectivityCheck` if only the probe is blocked. |
| `No client secret given …` | `PAD_SECRET` is unset and nothing was typed at the masked prompt. |
| `No valid EnvironmentId given …` | Three malformed GUIDs entered at the prompt. Pass it as a parameter instead. |
| `Installer failed with exit code …` | Download corrupt, or another install/upgrade of Power Automate in progress. Re-run with `-Reinstall`. |
| Registration fails | No application user for the app in that environment; Microsoft Flow Service permissions never admin-consented; expired or mistyped client secret; the app user lacks **Desktop Flows Machine Owner**; or a stale registration (re-run with `-Force`). |
| Registration fails: already registered | The machine is bound to another environment. Re-run with `-Force` — this breaks existing connections to it. |
| Machine registers but never goes Active | Machine-runtime service not running (the script tries to start it), or outbound connectivity dropped after registration. |
| `-EnableComputerUse` fails with **403**, `0x80072560` / *not a member of the organization* | The app has **no application user** in that environment. Registration succeeding proves nothing here — it goes through the Flow Service, which is a separate authorization path from Dataverse. Create the app user (see step 2 above). |
| `-EnableComputerUse` fails with **403**, *does not have ReadAccess/WriteAccess right(s) … Flow Machine Group* | The app user exists but only has **Desktop Flows Machine Owner**, which is User-level: it covers machines and groups *that user owns*. Machine groups are owned by whoever registered the machine, so the app user cannot see them. Needs Business-Unit depth — see the custom role below. |

## Security notes

- The client secret is only ever in `PAD_SECRET` and on the registration tool's
  stdin. It never appears in the command line, the console log, or the script's
  output. `PAD_SECRET` is cleared after registering.
- Give the application user the least role that works — **Desktop Flows Machine
  Owner** is enough to register machines; System Administrator is not required.

### Extra role needed for `-EnableComputerUse`

Registering a machine and flipping the computer-use flag need different rights.
**Desktop Flows Machine Owner** covers only machines and groups the app user
*owns*, and a machine group is owned by whoever registered the machine — so the
app user gets a 403 reading a group it did not create. There is no built-in role
with the right depth short of System Administrator, so add a small custom one:

1. admin.powerplatform.com → **Environments** → the environment → **Settings** →
   **Users + permissions** → **Security roles** → **+ New role**.
2. Name it (e.g. `PAD Computer Use`), business unit = root.
3. On the **Custom Entities** tab set the following, all at **Business Unit**
   depth:

   | Table | Rights | Needed for |
   |---|---|---|
   | Flow Machine Group | Read, Write | `-EnableComputerUse` |
   | Flow Machine | Read | machine lookup by name, when there is no local registration record |
   | Bot Component | Read, Write | [Probe-CuaConnection.ps1](Probe-CuaConnection.ps1) — the agent's Computer Use action |
   | Connection Reference | Read | reading which connection the agent resolves to |

   Connection Reference **Write** is deliberately not listed: repointing a
   connection reference makes Dataverse check the caller's permission on the
   *target connection*, and Computer Use connections are created with
   `allowSharing: false`, so a service principal can never hold it. Granting the
   privilege does not help — the write fails with `ConnectionAuthorizationFailed`
   regardless. Binding a connection for the first time is a portal step.
4. **Save**, then Application users → the app user → **Edit security roles** and
   tick the new role *in addition to* Desktop Flows Machine Owner.

Grant Read and Write together: the script reads the group first to skip a
redundant write, so a read-only grant just moves the 403 one line down.
- Client secrets expire. Note the expiry set in step 6 and rotate before it
  lapses, or new machine registrations will start failing.
