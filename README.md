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
- `SWA_DEPLOYMENT_TOKEN`

The deployment workflow selects `dev` or `prod` and deploys infrastructure plus backend and frontend artifacts to that instance.

### SWA linked backend and auth

- `frontendSkuName` defaults to `Standard` in Bicep to support SWA linked backends.
- SWA is linked to the API Container App resource so frontend requests can use `/api/*` on one domain.
- `frontend/staticwebapp.config.json` includes route protection and Entra login redirect behavior.
