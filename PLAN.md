# Azure RAG — Incremental Build Plan

We restart from a clean Azure subscription. The goal is a deploy pipeline that is **boringly reliable** before we add any features. We grow in tiers; each tier is one commit and must produce a green workflow before the next tier starts.

## Guiding principles
- One thing at a time. If a tier fails, the failure must be unambiguous.
- No managed identity, secrets, or RBAC until a resource actually needs to authenticate to another Azure resource.
- Container Apps managed environment lives in **`northeurope`** (westeurope has been hitting `AKSCapacityHeavyUsage`).
- Static Web App lives in **`westeurope`** (SWA is region-limited).
- The stable resource-name suffix is `substring(uniqueString(resourceGroup().id, environmentName), 0, 6)` — region-independent so we never orphan resources by switching regions.

---

## Tier 0 — Minimum viable deploy (this commit)
**Goal:** prove that the workflow can stand up a backend and a frontend end-to-end.

Resources:
- Container Apps managed environment (`northeurope`).
- Container App running the public placeholder image `mcr.microsoft.com/k8se/quickstart:latest`, external ingress on port 80.
- Static Web App (`westeurope`, Free).

What is **deliberately absent:**
- No ACR, no UAMI, no Key Vault, no Cosmos, no role assignments.
- No `az acr build`, no `az containerapp update`, no Key Vault purge step in the workflow.

Success criteria:
- `https://<backend>.<region>.azurecontainerapps.io/` returns the quickstart page.
- `https://<swa-host>` serves the built frontend.

---

## Tier 1 — Real backend image
**Adds:** ACR, UAMI, AcrPull role assignment, `az acr build`, `az containerapp update` with `--image <our-image>`. The Container App switches from the public placeholder to our own image.

Success criteria:
- Backend FQDN serves our FastAPI `/healthz`.

---

## Tier 2 — Data plane
**Adds:** Cosmos DB (Mongo API), Key Vault, Key Vault Secrets User role on the UAMI, KV secret for the Cosmos connection string, container env var pointing the app at the secret.

Success criteria:
- Backend can read/write a document end-to-end.

---

## Tier 3+ — Features (decide later)
Candidates, in no particular order: Azure OpenAI, Event Grid, Application Insights, custom domains, auth. Each is its own commit on top of a green Tier 2.

### Auth decision (locked for now)
- Keep Azure Static Web Apps built-in auth with Microsoft Entra ID.
- Keep backend principal parsing via `X-MS-CLIENT-PRINCIPAL`.
- Use Microsoft Entra MFA (Authenticator OTP challenge) for login security.
- Do **not** implement a custom in-app OTP modal or custom auth backend at this stage.
- Revisit only if we later need non-SWA hosting portability or consumer identity flows.

---

## Out of scope for now
- `prod` environment parity beyond what `dev` proves out.
- Multi-region or HA.
- Networking hardening (private endpoints, VNet integration).
