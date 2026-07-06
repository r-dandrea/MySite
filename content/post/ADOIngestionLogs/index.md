---
title: "No Account, No Problem - Ingesting Azure DevOps Audit Logs into Sentinel with a Service Principal"
description: "Microsoft's Azure DevOps Audit Logs connector for Sentinel forces you to sign in with a user account. Here's how I ditched that requirement and built a secret-free, service-principal-based ingestion pipeline from scratch with a Logic App, a DCR, and Key Vault."
date: 2026-07-06
image: cover.png
categories:
    - Azure
tags:
    - Microsoft Sentinel
    - Azure DevOps
    - Logic Apps
    - Data Collection Rule
    - Service Principal
    - Key Vault
---

# No Account, No Problem: Ingesting Azure DevOps Audit Logs into Sentinel with a Service Principal

🕑 _Reading time: ~10 minutes_

**📢**

_In this guide you'll learn why the native Azure DevOps Audit Logs connector for Microsoft Sentinel is a governance problem waiting to happen, and how to replace it with a fully service-principal-based pipeline - no user sign-in, no fragile service account, and (after the final step) no secrets in clear text at all._

📚 **Skip the theory?** Jump straight to [The Build](#-the-build-step-by-step).

---

## ⚠️ Why I Refused to Use the Connector's Account

Microsoft Sentinel ships with a codeless connector called **Azure DevOps Audit Logs (via Codeless Connector Platform)**. It looks convenient, but the moment you click **Connect** it sends you through an **OAuth authorization-code** flow and asks you to **sign in with an account**. That account becomes the identity that reads your audit logs forever.

From a security and operations standpoint, every option Microsoft leaves you with is bad:

| Option | Why it's a problem |
| --- | --- |
| **My own user account** | If I ever revoke my sessions, rotate my password, or leave the company, the refresh token dies and **you silently stop receiving logs**. Tying an org-wide security feed to one human is a single point of failure. |
| **A shared service account** | Now I own a licensed user with a password, an MFA exclusion (to keep automation alive), and a long-lived refresh token. That's exactly the kind of standing credential attackers love. Service accounts are **not** a good answer in 2026. |
| **App Client ID only** | Not supported by the connector - the authorization-code flow **requires** an interactive user login. You can't just hand it a client ID. |

So I threw the connector away and built the pipeline **from scratch using a Service Principal (App Registration)**. The service principal authenticates non-interactively, its permissions are explicit and scoped, and in the last step I move its secret into **Key Vault** so nothing sensitive lives in clear text.

**👉**

The end result: Azure DevOps audit events land in Sentinel through the **same custom table** the connector would have used (`ADOAuditLogs_CL`), but the identity behind it is a service principal I fully control - no human, no service account, no revocation surprises.

---

## 🧭 How the Pipeline Works

Before the steps, here's the mental model. The Logic App is only the **he data actually enters Log Analytics through a **Data Collection Rule (DCR)**:

```
Logic App (Service Principal auth)
  1. Recurrence trigger (every few minutes)
  2. Get secret from Key Vault
  3. Build startTime / endTime window
  4. HTTP GET  -> Azure DevOps Audit Log API   (audience = Azure DevOps)
  5. Condition -> only continue if events exist
  6. HTTP POST -> DCE Logs Ingestion endpoint  (audience = https://monitor.azure.com)
        |
        v
   Data Collection Rule (transformKql) -> ADOAuditLogs_CL table -> Microsoft Sentinel
```

Two different tokens, same service principal:

* the **GET** asks for a token for **Azure DevOps** (resource ID `499b84ac-1321-427f-aa17-267ca6975798`),
* the **POST** asks for a token for **`https://monitor.azure.com`** to write through the DCR.

**⚙**

The DCR is **not optional**. You can't POST straight into a custom table - the Logs Ingestion API always writes *through* a DCR, which validates the incoming schema, runs an optional KQL transform, and routes rows  the destination table.

---

## ✅ The Build (Step by Step)

### Prerequisites

* Your Azure DevOps organization is backed by the **same Entra ID tenant** as your Azure subscription.
* **Auditing is enabled** on the organization (`Organization Settings → Auditing`).
* You have a **Log Analytics workspace** connected to Microsoft Sentinel.
* Permissions: **Owner/Contributor** on the resource group, and **Project Collection Administrator** on Azure DevOps.

---

### 1️⃣ Create the App Registration

1. **Entra ID → App registrations → New registration**. Give it a name like `AzureDevOpsSentinelLog`.
2. Copy the **Application (client) ID** and the **Directory (tenant) ID** from the Overview blade.
3. Go to **Certificates & secrets → New client secret**, and copy the **Value** (not the Secret ID - the value is only shown once).

**⚠️** Keep that secret somewhere safe for now; in **Step 6** we'll move it into Key Vault so it never lives in the workflow.

---

### 2️⃣ Add the Service Principare DevOps supports service principals and managed identities as first-class members of an organization, so we grant it access exactly like a user.

1. `dev.azure.com/<your-org>` → **Organization Settings → Users → Add users**.
2. Search for the app by **name** (`AzureDevOpsSentinelLog`) or by **Client ID**, set **Access level = Basic**.
3. Grant it the ability to **read the audit log**. Auditing lives at the organization level, so add the service principal to a group that can read it (for example **Project Collection Administrators**).

**💡** If you don't want to hand it PCA, create a **dedicated group** with only the audit-read capability and add the SP there - least privilege wins.

---

### 3️⃣ Find the DCR & Copy the Log Ingestion Endpoint

If you had previously tried the native connector, Sentinel already created a DCR (mine was tagged `createdBy: Sentinel`) that points to `ADOAuditLogs_CL`. You can **reuse it** or create your own dedicated one - either way you need three values.

The DCR lared its input stream as **`Custom-ADOAuditLogs`** and did the field mapping itself in its `transformKql`:

```kql
source
| extend TimeGenerated = todatetime(timestamp)
| project TimeGenerated, ActionId = actionId, ActivityId = activityId, ActorUPN = actorUPN,
          Area = area, Category = category, Data = data, Details = details, Id = id,
          IpAddress = ipAddress, ProjectName = projectName, ScopeType = scopeType /* ...etc... */
```

**👉** This is a great shortcut: because the transform expectshe **raw lowercase fields** exactly as the Azure DevOps API returns them (`actionId`, `timestamp`, `data`...), you send the API payload **as-is** - no reshaping in the Logic App.

Grab these three values (portal or CLI):

```bash
RG="<dcr-resource-group>"
DCR="<your-dcr-name>"

# Immutable ID (goes in the POST URL)
az monitor data-collection rule show -g "$RG" -n "$DCR" --query "immutableId" -o tsv

# The input stream name
az monitor data-collection rule show -g "$RG" -n "$DCR" --query "streamDeclarations" -o json

# The DCE this DCR uses -> its Logs Ingestion endpoint
DCE_ID=$(az monitor data-collection rule show -g "$RG" -n "$DCR" --query "dataCollectionEndpointId" -o tsv)
az monitor data-collection endpoint show --ids "$DCE_ID" --query "logsIngestion.endpoint" -o tsv
```

You now have: **DCE ingestion endpoint**, **DCR immutable ID**, and **stream name** (`Custom-ADOAuditLogs`).

---

### 4️⃣ Assign the DCR Permission to the Service Principal

The service principal must be allowed to write through the DCR. That role is **Monitoring Metrics Publisher**.

Portal: open the DCR → **Access control (IAM) → Add role assignment → Monitoring Metrics Publisher →** select your app → **Review + assign**.

Or CLI:

```bash
DCR_ID=$(az monection rule show -g "$RG" -n "$DCR" --query id -o tsv)

az role assignment create \
  --assignee "<client-id>" \
  --role "Monitoring Metrics Publisher" \
  --scope "$DCR_ID"
```

**⚠️** Role propagation can take **5-10 minutes**. If your first POST returns **403**, this is almost always why - wait and retry.

---

### 5️⃣ Build the Logic App

Create a **Logic App**, then build this sequence in the designer.

**Trigger - Recurrence:** every `5` minutes.

**Compose - `startTime`:**
```tes(utcNow(), -10)
```
**Compose - `endTime`:**
```
utcNow()
```

**⚙** I use a 10-minute window on a 5-minute schedule on purpose - a little overlap means events that land late in the Azure DevOps audit log are never missed. We de-duplicate later in KQL.

**HTTP - GET (read the audit log):**

* **Method:** `GET`
* **URI:**
```
tps://auditservice.dev.azure.com/<your-org>/_apis/audit/auditlog?startTime=@{outputs('startTime')}&endTime=@{outputs('endTime')}&api-version=7.2-preview.1
```
* **Authentication → Active Directory OAuth:**

| Field | Value |
| --- | --- |
| Authority | `https://login.microsoftonline.com` |
| Tenant | `<tenant-id>` |
| **Audience** | `499b84ac-1321-427f-aa17-267ca6975798` |
| Client ID | `<client-id>` |
| Credential type | `Secret` |
| Secret | *(the client sect - replaced by Key Vault in Step 6)* |

**Condition - only continue if there are events:**
```
length(body('HTTP_GET')?['decoratedAuditLogEntries'])   is greater than   0
```

**HTTP - POST (send to Sentinel), inside the True branch:**

* **Method:** `POST`
* **URI:**
```
<DCE-ingestion-endpoint>/dataCollectionRules/<dcr-immutable-id>/streams/Custom-ADOAuditLogs?api-version=2023-01-01
```
* **Headers:** `Content-Type: application/json`
* **Body:**
```
@body('HTTP_GET')?['decoratedAuditLogEntries']
```
* **Authentication → Active Directory OAuth:** same as the GET, but change only the **Audience** to `https://monitor.azure.com`.

---

### 6️⃣ Move the Secret into Key Vault

Now kill the clear-text secret.

1. Store the client secret in **Key Vault** as a secret (e.g. `ADOSentinel-LogicApp-Secret`Add a **Key Vault → Get secret** action at the top of the workflow.
3. In **both** HTTP actions, replace the `Secret` value with a reference to that action:
```
@{body('Get_secret')?['value']}
```
4. Give the Logic App's connection **Get** permission on the vault's secrets (Key Vault **Access policies** → the *Azure Logic Apps* connection → `Get`).

**✅** From here on there is **no secret in the workflow definition** - the Logic App fetches it at runtime and Logic Apps marks that actiots/outputs as secured.

---

### 7️⃣ Verify Events Land in the SIEM

Run the workflow. The POST should return **204 No Content**. Then, in **Sentinel → Logs**, remember that `TimeGenerated` equals the *original event time*, so query by ingestion time to avoid chasing your tail:

```kql
ADOAuditLogs_CL
| where ingestion_time(o(30m)
| sort by TimeGenerated desc
```

Because of the intentional window overlap, de-duplicate by the unique event `Id`:

```kql
ADOAuditLogs_CL
| summarize arg_max(TimeGenerated, *) by Id
```

**⏱** In under a minute after a successful POST (allow a little longer the very first time a custom table is written), your Azure DevOps audit events show up in Sentinel - gested by a service principal, with zero standing user credentials.

---

## 🐛 The Gotchas That Cost Me Time

These are the exact traps I hit - documenting them so you don't.

| Symptom | Root cause | Fix |
| --- | --- | --- |
| **POST returns 204 but no rows appear** | The Body field was `body('HTTP_GET')?[...]` **without the leading `@`**, so the Logic App sent the *literal string* instead of the array. The ingestion API happily accepts it (204) and silently drops it. | Prefix the expression with **`@`** so it evaluates: `@body('HTTP_GET')?['decoratedAuditLogEntries']`. |
| **`UnsupportedMediaType`** | Missing/incorrect content type. | Add header **`Content-Type: application/json`** to the POST. |
| **GET 401 / 403** | Service principal not added to the Azure DevOps org, or lacking audit-read rights. | Revisit **Step 2**. |
| **POST 403** | `Monitoring Metrics Publisher` not assigned (or not ppagated). | Revisit **Step 4**, wait a few minutes. |
| **Empty result `decoratedAuditLogEntries: []`** | Genuinely no audit events in that time window - this is normal, not an error. | Widen the window for testing (`-120` minutes). |
| **"I see nothing in the last 30 minutes"** | The Logs time picker filters on `TimeGenerated`, which is the *event* time, not the ingestion time. | Query with **`ingestion_time()`** and set the picker to a wide range. |

**⚠️** `Parse JSON` is tempting but onal here - and its strict schema validation will **fail** on `null` values (many Azure DevOps system events have `null` `ipAddress`, `userAgent`, etc.). I removed it entirely and referenced the GET body directly. Fewer moving parts, no false failures.

---

## 🧠 Final Considerations

The native connector isn't broken - it's jusbuilt around an authentication model that doesn't fit a security-conscious environment. Anchoring an organization-wide audit feed to a **human's refresh token** or a **standing service account** trades long-term risk for short-term convenience.

By rebuilding the pipeline around a **service principal**, an explicit **DCR**, and a **Key Vault**-backed secret, you get:

* **No interactive login** and no dependency on any single person.
* **Explicit, scoped permissions** (audit-read on Azure DevOps, `Monitoring Metrics Publisher` on the DCR) that are trivial to audit and revoke.
* **No secrets in clear text** once the value lives in Key Vault - and a clean path to swap it for a certificate or a managed identity later.

Same destination table, same Sentinel experience - but an identity you actually control. That's the whole point.

**✅**

**If the tool Microsoft gives you forces a weak identity model, don't accept it - rebuild the plumbing around a principal you can govern. A few Logic App actions are a smallrice for removing a standing credential from your attack surface.**

---

**Sources and References:**

* Azure DevOps Audit Log API: <https://learn.microsoft.com/en-us/rest/api/azure/devops/audit/audit-log>
* Logs Ingestion API in Azure Monitor: <https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-ingestion-api-overview>
* Data collection rules (DCR) overview: <https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview>
* Service principals & managed identities in Azure DevOps: <https://learn.microsoft.com/en-us/azure/devops/integrate/get-started/authentication/service-principal-managed-identity>
* Authenticate Logic Apps with managed identity / OAuth: <https://learn.microsoft.com/en-us/azure/logic-apps/authenticate-with-managed-identity>

