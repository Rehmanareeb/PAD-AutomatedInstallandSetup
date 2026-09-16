# Agent-env-testing-1 → Web Security Secrets Analysis

Sources analysed:

| Source | Path |
| --- | --- |
| Config sample | `settings.js` (attachment `2678a879…`, 59 lines) |
| Network capture | `copilotstudio.microsoft.com_Directline-Secrets.har` (21 entries) |
| Discovery script | `HandOver-Scripts/Agent-env-testing.ps1` |

---

## 1. What `Agent-env-testing.ps1` produces

The script at `HandOver-Scripts/Agent-env-testing.ps1` outputs **connection routing data only** — it never
reads or prints a Web channel security secret.

| Step | Output | How it is derived |
| --- | --- | --- |
| 1 | `environmentApiBase` | `https://<envGuid-without-dashes, dot before last 2 chars>.environment.api.powerplatform.com` |
| 2 | `agent1DirectConnectUrl` | `<base>/copilotstudio/dataverse-backed/authenticated/bots/cr720_Agent1TestScript/conversations?api-version=2022-03-01-preview` |
| 2 | `agent2DirectConnectUrl` | same with `cr720_Agent2UITesting` |
| 3 | `agent2ChannelBotId` | `bot` claim decoded out of the JWT returned by `/powervirtualagents/botsbyschema/<schema>/directline/token` |
| 4 | `agent2TokenUrl` | `https://powerva.microsoft.com/api/botmanagement/v1/directline/directlinetoken?botId=<agent2ChannelBotId>` (a **temporary** token endpoint) |

The emitted environment variables are:

```
NEXT_PUBLIC_AGENT1_DIRECT_CONNECT_URL=…
NEXT_PUBLIC_AGENT2_BOT_ID=…
NEXT_PUBLIC_AGENT2_TOKEN_URL=…
```

Plus it writes `Copilot-Agent-Connection-Config.json` and a throwaway `Agent2-DirectLine-Token.json`.

**It does not emit the app registration client ID, the tenant ID, or any Direct Line secret.** Those come
from Entra ID and from the Copilot Studio **Channels → Web app → Direct Line secrets** blade — which is
exactly what the HAR file captured.

---

## 2. Where the secrets sit in the HAR

All 21 entries were inspected. The secrets are **request #16**, `GET /api/botmanagement/v1/channels/directline`
(HTTP 200, `application/json`), captured while the **Direct Line secrets** blade was open in Copilot Studio.

**Response body (verbatim):**

```json
[{"key":"",
  "key2":""}]
```

- `key` and `key2` are the two standard Direct Line **secret keys** for the same bot — Copilot Studio shows
  them as "Secret 1 / Secret 2" with per-key copy buttons. Each is 169 characters (84 + `.` + 84) and both
  share the same first 84-char segment (`…AZBS1JyD`), which is how you can tell they belong to one bot.
- **Request #14** `GET /channels/directline/accesspolicy` returned `{"isAnonymousAccessDisabled":true}` —
  anonymous (unauthenticated) Direct Line access is **disabled**, so a secret or a token is mandatory.
- The HAR holds **no** `environment.api.powerplatform.com` traffic at all. The capture went through the
  legacy island gateway `powervamg.us-il107.gateway.prod.island.powerapps.com`, i.e. the secrets blade was
  reached via the `powerva.microsoft.com` route that `Agent-env-testing.ps1` also uses in step 4.

### Identity of the bot behind those secrets (from request/response headers + telemetry)

| Field | Value | Source |
| --- | --- | --- |
| Bot schema name | `cr720_Agent2UITesting` | telemetry payload (`botSchemaName`) |
| Dataverse bot id (`x-cci-cdsbotid`) | `f9d2ac3a-70a3-4c34-af14-d4336655795e` | request header #16 |
| Direct Line routing bot id (`x-cci-botid`) | `d64b741f-9e2b-4b17-2b77-d7e9ece9f9ce` | request header #16 |
| Environment id | `cb1f75b0-80a1-e1f6-bd64-3b271177f91e` | `x-cci-bapenvironmentid` |
| Tenant id | `cc7374ac-e69f-4e98-942a-1023569972ad` | `x-cci-tenantid` |
| Org id | `05c7b75e-b79c-f111-9969-6045bd07ba22` | `x-cci-organizationid` |
| Signed-in user object id | `489b6806-c1f0-4680-be06-9af82e91fd9b` | `x-ms-client-principal-id` |
| Solution | `CUAExecutionValidator` | `x-ms-solution-unique-name` |

So the capture is the **`cr720_Agent2UITesting` agent**, and the page was reached from solution
`CUAExecutionValidator` — not from a file/solution literally named `agent-env-testing-1`. The only
`agent-env-testing` the HAR contains is the local script name for the discovery step.

Derived Direct Connect URL for that bot (same rule the script uses):

```
https://cb1f75b080a1e1f6bd643b271177f9.1e.environment.api.powerplatform.com/copilotstudio/dataverse-backed/authenticated/bots/cr720_Agent2UITesting/conversations?api-version=2022-03-01-preview
```

---

## 3. The secrets in `settings.js`, and the mismatch

`settings.js` is the Microsoft `@microsoft/agents-copilotstudio-client` sample connection-settings file.
The secrets it carries:

| Variable | Line | Value | Kind |
| --- | --- | --- | --- |
| `this.appClientId` | 47 | `5e69a3e2-b3bc-4ae2-8df9-557556be7cd5` | Entra **app registration client ID** (public client, for MSAL token acquisition) |
| `this.tenantId` | 52 | `edda99bb-bab6-4c4c-8aa1-4b99e8e09c1b` | Entra **tenant ID** (note: differs from the tenant in the HAR) |
| `this.agent2DirectLineSecret` | 53 | `Ac8DM6sg…AZBS249u.AcrjQFaS…AZBSQHTx` | **Web channel security secret — Direct Line secret, Secret 1** |
| `this.authority` | 57 | `https://login.microsoftonline.com` | MSAL authority host |
| `directConnectUrl` / `directConnectUrl2` | 27–28 | `…20bbbb7691c1efdebf328a54683361.04.environment.api.powerplatform.com/…/bots/cr720_Agent1TestScript` etc. | Direct Connect URLs (environment id baked into the host, so `environmentId`/`schemaName` are intentionally blank) |

The `agent2DirectLineSecret` key is the same 169-char, two-segment, 84-char-prefix shape as the HAR keys —
it is a genuine Direct Line secret for a **different** bot registration:

| | `settings.js` | HAR capture |
| --- | --- | --- |
| Secret region/infra tag | `…QJ99CHACi5YpzA…` | `…QJ99CIAC24pbEA…` |
| Bot | `cr720_Agent2UITesting` @ env `20bbbb7691c1efdebf328a54683361` | `cr720_Agent2UITesting` @ env `cb1f75b0-80a1-e1f6-bd64-3b271177f91e` |
| Tenant | `edda99bb-bab6-4c4c-8aa1-4b99e8e09c1b` | `cc7374ac-e69f-4e98-942a-1023569972ad` |
| Host style | `*.environment.api.powerplatform.com` | `powervamg.us-il107.gateway.prod.island.powerapps.com` |

**Conclusion: the HAR secrets and the `settings.js` secret are not interchangeable.** Direct Line secrets are
scoped to one bot registration in one environment in one tenant. Dropping the HAR keys into this `settings.js`
would produce a 403 on the first `POST /conversations` because the MSAL access token from
`edda99bb…`/`5e69a3e2…` does not authorize a bot in tenant `cc7374ac…`. The HAR keys and the HAR environment
ID go together; the `edda99bb…` app registration + tenant and the `20bbbb7691…` Direct Connect URLs go together.

There is no `cr720_Agent1TestScript` Direct Line secret anywhere in the capture — only the Agent 2 bot's
secrets were retrieved.

---

## 4. Handling notes

- These are **live credentials** now stored in plaintext in three places (HAR, `settings.js`, this document).
  Anyone holding a Direct Line secret can open a conversation with the bot as an anonymous user up to the
  channel's quota, so treat them as leaked: rotate both keys in Copilot Studio
  (**Settings → Channels → Web app → Direct Line secrets → regenerate**) and re-capture a sanitised HAR if a
  reference is needed. `context.md:445` already flags the same class of problem
  (`Agent2-ManualAuth-AUtomation.ps1:8` holds a plaintext secret).
- Prefer the pattern `Agent-env-testing.ps1` recommends: keep the stable
  `directConnectUrl` / `tokenUrl` + bot ID in config and let the frontend mint a short-lived token at
  runtime, instead of shipping a long-lived secret in a front-end bundle. A secret embedded in `settings.js`
  is `window`-visible and therefore effectively public.
- The Direct Line **secret** (`settings.js:53`) is not the same object as the Direct Line **token** that
  `Agent-env-testing.ps1` step 4 requests. The secret is long-lived; the token expires (the script prints
  `exp`). `settings.js` is using the secret, which works because
  `@microsoft/agents-copilotstudio-client` exchanges it for a token internally — but it is the weakest of the
  available options.

---

## 5. Field-by-field fill-in for a fresh `settings.js`

Swap the three bolded values to switch this sample to the environment captured in the HAR:

```js
directConnectUrl:  'https://cb1f75b080a1e1f6bd643b271177f9.1e.environment.api.powerplatform.com/copilotstudio/dataverse-backed/authenticated/bots/cr720_Agent2UITesting/conversations?api-version=2022-03-01-preview',
this.appClientId  = '<app registration client id registered in tenant cc7374ac-e69f-4e98-942a-1023569972ad>',   // NOT known from the HAR
this.tenantId     = 'cc7374ac-e69f-4e98-942a-1023569972ad',
this.agent2DirectLineSecret = '<secret from Copilot Studio for THIS bot>',
```

The app client ID for that tenant is **not** recoverable from the HAR — the capture is a delegated,
cookie-authenticated Copilot Studio session (`x-ms-client-principal-id`), not an app-only flow, so no client
ID is present. It must be supplied from the customer's app registration.
