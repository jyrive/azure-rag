# Azure RAG

This repository starts with a local-first Azure RAG scaffold:

- SvelteKit frontend for the user experience
- FastAPI backend for API and orchestration
- Bicep infrastructure for Azure dev and prod environments
- GitHub Actions for repeatable deployment

## Local development

1. Copy `.env.example` to `.env` and adjust values if needed.
2. Install frontend dependencies:

```bash
cd frontend
npm install
```

3. Install backend dependencies:

```bash
cd backend
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

4. Start both services with Docker Compose:

```bash
docker compose up --build
```

5. Or run them separately:

```bash
cd backend
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

```bash
cd frontend
npm run dev -- --host 0.0.0.0 --port 5173
```

## Azure deployment model

- `infra/main.bicep` provisions a dev or prod environment.
- GitHub Actions deploy the infrastructure and build/publish the backend image.
- Separate GitHub environments should hold the SWA deployment token for dev and prod.

### Included cloud resources

- Azure Container Registry for backend image builds
- Azure Container Apps for FastAPI backend and worker app
- Azure Static Web Apps for SvelteKit frontend
- Azure Key Vault with RBAC enabled
- Azure Cosmos DB (Mongo API account)
- Azure OpenAI account with chat and embedding deployments
- Azure Event Grid topic and subscription to worker webhook

The backend receives a managed identity and reads cloud values from Key Vault at runtime.

### Infrastructure layout

The infrastructure is split into modules under `infra/modules`:

- `core.bicep`: identity, key vault, ACR, Cosmos DB, OpenAI, Event Grid topic, Container Apps environment
- `apps.bicep`: API and worker container apps
- `eventing.bicep`: Event Grid subscription wired to worker endpoint
- `access.bicep`: RBAC role assignments
- `frontend.bicep`: Static Web App

`infra/main.bicep` orchestrates these modules for both `dev` and `prod`.

### API endpoints

- `POST /api/rag/index`: index a document with embedding
- `POST /api/rag/chat`: query documents and generate an answer with Azure OpenAI
- `POST /api/events/publish`: publish domain events to Event Grid
- `POST /api/worker/eventgrid`: Event Grid webhook endpoint for worker processing

For local testing, you can set `EVENTGRID_TOPIC_ENDPOINT` and `EVENTGRID_TOPIC_KEY` directly in `.env`.

RAG endpoints support tenant-aware filtering from the `X-MS-CLIENT-PRINCIPAL` header. If you set `REQUIRE_TENANT_CONTEXT=true`, calls without company claim context are rejected.
By default, indexing and event publishing require `administrator` or `companyadmin` role claims. You can change indexing behavior locally with `REQUIRE_ADMIN_FOR_INDEX`.
Policy behavior:

- `companyadmin`: restricted to its own `company_id` claim; cannot index or publish for another company.
- `administrator`: may operate across companies when `ALLOW_ADMIN_CROSS_COMPANY=true`.

Admin route:

- `GET /api/admin/tenant-context`: requires `administrator` role and returns parsed tenant/user/roles context.

At first database access, the backend attempts to create tenant indexes and a vector search index. In local or non-vector-capable environments, vector index bootstrap warnings are surfaced in `/api/config`.

### GitHub environment secrets

Create GitHub Environments named `dev` and `prod`, then set these secrets in each environment:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

The deployment workflow selects `dev` or `prod` and resolves the Static Web Apps deployment token from Azure at runtime.

### Smart deployment modes

The workflow now supports selective deployment with reliability-first defaults.

- `push` to `main`: auto-detects changed paths and deploys only impacted components.
- `workflow_dispatch`: supports manual control with these inputs:
- `smart_mode=true` keeps selective logic active.
- `force_full=true` overrides everything and runs full backend + frontend + infra deployment.
- `deploy_backend`, `deploy_frontend`, `deploy_infra`: `auto|on|off` selectors for manual runs.

Safety behavior:

- If change detection cannot determine scope safely, the workflow falls back to full deployment.
- If infra is selected without backend build, workflow reuses the currently deployed backend image.
- If required existing resources or outputs are missing, the run fails early with remediation guidance.

## Cosmos DB serverless migration

Cosmos DB Mongo API cannot switch an existing account from provisioned throughput to serverless in place.
This repo now deploys a new serverless account name and keeps the old account until you copy data and validate.

### 1) Deploy infra update

Push to `main` (or run workflow dispatch) so `infra/main.bicep` creates the new serverless Cosmos account.

### 2) Copy data from old account to new account

Install backend dependencies locally first (includes `pymongo`):

```bash
cd backend
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
cd ..
```

Run migration helper:

```bash
scripts/migrate-cosmos-serverless.sh dev
```

If auto-detection of the old account fails:

```bash
scripts/migrate-cosmos-serverless.sh dev <oldAccountName> <newServerlessAccountName>
```

### 3) Validate app-level read/write

```bash
scripts/check-deploy.sh dev
```

This confirms health, Key Vault secret resolution, and Cosmos round-trip behavior against the new connection string.

### 4) Remove old provisioned account after validation

List Mongo accounts:

```bash
az cosmosdb list -g rg-azure-rag-dev --query "[?kind=='MongoDB'].name" -o tsv
```

Delete the old provisioned account only after successful validation:

```bash
az cosmosdb delete -g rg-azure-rag-dev -n <oldProvisionedAccountName> --yes
```

### SWA linked backend and auth

- `frontendSkuName` defaults to `Standard` in Bicep to support SWA linked backends.
- SWA is linked to the API Container App resource so frontend requests can use `/api/*` on one domain.
- `frontend/staticwebapp.config.json` includes route protection and Entra login redirect behavior.

## Entra SSO and MFA/OTP (minimal setup)

This project uses Azure Static Web Apps built-in authentication with Microsoft Entra ID.
It is SSO-ready by default and does not require NextAuth/Auth.js for the current architecture.

### Why this setup

- Minimal moving parts: SWA handles sign-in, session, and identity headers.
- Backend already parses `X-MS-CLIENT-PRINCIPAL` for roles and tenant context.
- Future SSO support remains straightforward through Entra tenant settings.

### Configure Entra for personal testing

1. Keep the SWA auth config in `frontend/staticwebapp.config.json` as-is.
2. In Microsoft Entra, use a single-tenant app configuration for initial testing.
3. Assign yourself the app roles needed by backend policies (`administrator` or `companyadmin`) if required.
4. Enable MFA for your user and prefer Microsoft Authenticator TOTP.

### OTP note

- MFA through Entra (Authenticator OTP challenge) is the simplest low-cost path.
- Standalone custom OTP/passwordless flows are intentionally out of scope here.

### Test flow

1. Open the frontend and click **Login with Entra**.
2. Complete sign-in and MFA challenge.
3. Verify the auth panel on the home page (authenticated state, provider, roles).
4. Call `GET /api/me` and confirm principal claims are present.
5. Validate role-gated endpoint behavior:
	- `GET /api/admin/tenant-context` returns `200` for admin role.
	- The same endpoint returns `403` for non-admin users.

## JIT user provisioning and app roles

The backend supports just-in-time (JIT) user provisioning with a default app role.

- First successful login (or first authenticated API request) automatically creates a user profile in Cosmos DB.
- New users receive the default app role from `DEFAULT_APP_ROLE` (defaults to `member`).
- Effective authorization roles are the union of:
	- Entra/SWA principal roles (`claims.roles` and `userRoles`)
	- Stored app roles from the user profile
	- Implicit `authenticated` role for signed-in users

This means a separate registration page is not required.

### Role management endpoint

Administrators can override app roles for any user:

- `PUT /api/admin/users/{user_id}/roles`
- `GET /api/admin/users?q=<search>&limit=8` for admin user lookup/autocomplete
- Requires `administrator` role
- Request body:

```json
{
	"roles": ["member", "companyadmin"],
	"company_id": "optional-company-id"
}
```

If `roles` is empty, the backend applies the configured default app role.
