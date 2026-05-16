from __future__ import annotations

import base64
from datetime import datetime, timezone
import json
import os
import re
from typing import Any

from azure.core.credentials import AzureKeyCredential
from azure.eventgrid import EventGridEvent, EventGridPublisherClient
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.keyvault.secrets import SecretClient
from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from openai import AzureOpenAI
from pydantic import BaseModel, Field
from pymongo import MongoClient

app = FastAPI(title="Azure RAG API", version="0.1.0")

# Enable CORS for local development and cloud deployments
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

_cached_runtime_config: dict[str, Any] | None = None
_mongo_client: MongoClient | None = None
_openai_client: AzureOpenAI | None = None
_indexes_bootstrapped = False
_user_indexes_bootstrapped = False


def decode_client_principal(raw_principal: str | None) -> dict[str, Any] | None:
    if not raw_principal:
        return None

    try:
        payload = base64.b64decode(raw_principal).decode("utf-8")
        principal = json.loads(payload)
    except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
        return None

    return principal


def _build_runtime_config() -> dict[str, Any]:
    key_vault_url = os.getenv("KEY_VAULT_URL", "")
    cosmos_secret_name = os.getenv("KEYVAULT_COSMOS_SECRET_NAME", "cosmos-connection-string")
    openai_endpoint_secret_name = os.getenv("KEYVAULT_OPENAI_ENDPOINT_SECRET_NAME", "openai-endpoint")
    eventgrid_endpoint_secret_name = os.getenv("KEYVAULT_EVENTGRID_ENDPOINT_SECRET_NAME", "eventgrid-topic-endpoint")
    eventgrid_key_secret_name = os.getenv("KEYVAULT_EVENTGRID_KEY_SECRET_NAME", "eventgrid-topic-key")

    config: dict[str, Any] = {
        "keyVaultEnabled": bool(key_vault_url),
        "cosmosConnectionString": os.getenv("COSMOS_CONNECTION_STRING", ""),
        "openAiEndpoint": os.getenv("AZURE_OPENAI_ENDPOINT", ""),
        "openAiChatDeployment": os.getenv("AZURE_OPENAI_CHAT_DEPLOYMENT", ""),
        "openAiEmbeddingDeployment": os.getenv("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", ""),
        "eventGridTopicEndpoint": os.getenv("EVENTGRID_TOPIC_ENDPOINT", ""),
        "eventGridTopicKey": os.getenv("EVENTGRID_TOPIC_KEY", ""),
        "requireTenantContext": os.getenv("REQUIRE_TENANT_CONTEXT", "false").lower() == "true",
        "requireAdminForIndex": os.getenv("REQUIRE_ADMIN_FOR_INDEX", "true").lower() == "true",
        "allowAdminCrossCompany": os.getenv("ALLOW_ADMIN_CROSS_COMPANY", "true").lower() == "true",
        "vectorDimensions": int(os.getenv("RAG_VECTOR_DIMENSIONS", "1536")),
        "secretLoadErrors": [],
        "bootstrapWarnings": [],
    }

    if not key_vault_url:
        return config

    try:
        credential = DefaultAzureCredential()
        secret_client = SecretClient(vault_url=key_vault_url, credential=credential)

        try:
            cosmos_secret = secret_client.get_secret(cosmos_secret_name)
            if cosmos_secret.value:
                config["cosmosConnectionString"] = cosmos_secret.value
        except Exception as error:  # noqa: BLE001
            config["secretLoadErrors"].append(f"{cosmos_secret_name}: {error}")

        try:
            openai_endpoint_secret = secret_client.get_secret(openai_endpoint_secret_name)
            if openai_endpoint_secret.value:
                config["openAiEndpoint"] = openai_endpoint_secret.value
        except Exception as error:  # noqa: BLE001
            config["secretLoadErrors"].append(f"{openai_endpoint_secret_name}: {error}")

        try:
            eventgrid_endpoint_secret = secret_client.get_secret(eventgrid_endpoint_secret_name)
            if eventgrid_endpoint_secret.value:
                config["eventGridTopicEndpoint"] = eventgrid_endpoint_secret.value
        except Exception as error:  # noqa: BLE001
            config["secretLoadErrors"].append(f"{eventgrid_endpoint_secret_name}: {error}")

        try:
            eventgrid_key_secret = secret_client.get_secret(eventgrid_key_secret_name)
            if eventgrid_key_secret.value:
                config["eventGridTopicKey"] = eventgrid_key_secret.value
        except Exception as error:  # noqa: BLE001
            config["secretLoadErrors"].append(f"{eventgrid_key_secret_name}: {error}")
    except Exception as error:  # noqa: BLE001
        config["secretLoadErrors"].append(str(error))

    return config


def get_runtime_config() -> dict[str, Any]:
    global _cached_runtime_config
    if _cached_runtime_config is None:
        _cached_runtime_config = _build_runtime_config()
    return _cached_runtime_config


class IndexDocumentRequest(BaseModel):
    document_id: str = Field(min_length=1)
    text: str = Field(min_length=1)
    metadata: dict[str, Any] = Field(default_factory=dict)


class ChatRequest(BaseModel):
    question: str = Field(min_length=1)
    top_k: int = Field(default=3, ge=1, le=20)


class PublishEventRequest(BaseModel):
    event_type: str = Field(min_length=1)
    subject: str = Field(min_length=1)
    data: dict[str, Any] = Field(default_factory=dict)


class UpdateUserRolesRequest(BaseModel):
    roles: list[str] = Field(default_factory=list)
    company_id: str | None = None


def _normalize_role(value: str) -> str:
    return value.strip().lower().replace(" ", "")


def get_default_app_role() -> str:
    role = _normalize_role(os.getenv("DEFAULT_APP_ROLE", "member"))
    return role or "member"


def _claim_value(principal: dict[str, Any], claim_types: list[str]) -> str | None:
    claims = principal.get("claims", [])
    lookup = {c.lower() for c in claim_types}

    for claim in claims:
        claim_type = str(claim.get("typ", "")).lower()
        if claim_type in lookup:
            value = claim.get("val")
            if value:
                return str(value)

    return None


def get_principal_roles(principal: dict[str, Any] | None) -> set[str]:
    if not principal:
        return set()

    roles: set[str] = set()
    claims = principal.get("claims", [])
    for claim in claims:
        claim_type = str(claim.get("typ", "")).lower()
        if claim_type != "roles":
            continue

        value = claim.get("val")
        if isinstance(value, str):
            for item in value.split(","):
                normalized = _normalize_role(item)
                if normalized:
                    roles.add(normalized)

    user_roles = principal.get("userRoles")
    if isinstance(user_roles, list):
        for role in user_roles:
            if isinstance(role, str):
                normalized = _normalize_role(role)
                if normalized:
                    roles.add(normalized)

    roles.add("authenticated")
    return roles


def require_roles(roles: set[str], allowed_roles: set[str], detail: str) -> None:
    if not roles.intersection(allowed_roles):
        raise HTTPException(status_code=403, detail=detail)


def enforce_company_scope(
    tenant_context: dict[str, Any],
    target_company_id: str | None,
    runtime_config: dict[str, Any],
    action: str,
) -> str | None:
    roles = tenant_context["roles"]
    actor_company_id = tenant_context["companyId"]

    if "administrator" in roles:
        if target_company_id and not runtime_config["allowAdminCrossCompany"] and actor_company_id and target_company_id != actor_company_id:
            raise HTTPException(status_code=403, detail=f"Administrator cross-company {action} is disabled.")
        return target_company_id or actor_company_id

    if "companyadmin" in roles:
        if not actor_company_id:
            raise HTTPException(status_code=403, detail="Company admin role requires company context claim.")
        if target_company_id and target_company_id != actor_company_id:
            raise HTTPException(status_code=403, detail=f"Company admin cannot {action} outside own company.")
        return actor_company_id

    raise HTTPException(status_code=403, detail=f"Insufficient role to {action}.")


def merge_principal_and_app_roles(principal_roles: set[str], app_roles: list[str]) -> set[str]:
    merged = set(principal_roles)

    for role in app_roles:
        if isinstance(role, str):
            normalized = _normalize_role(role)
            if normalized:
                merged.add(normalized)

    if merged:
        merged.add("authenticated")

    return merged


def get_tenant_context(x_ms_client_principal: str | None) -> dict[str, Any]:
    principal = decode_client_principal(x_ms_client_principal)
    if not principal:
        return {
            "principal": None,
            "companyId": None,
            "userId": None,
            "roles": set(),
            "appRoles": [],
        }

    company_id = _claim_value(principal, ["company_id", "tenant_id", "tid"])
    user_id = principal.get("userId") or _claim_value(principal, ["oid", "sub"])

    return {
        "principal": principal,
        "companyId": company_id,
        "userId": str(user_id) if user_id else None,
        "roles": get_principal_roles(principal),
        "appRoles": [],
    }


def get_mongo_database() -> Any:
    global _mongo_client

    runtime_config = get_runtime_config()
    connection_string = runtime_config.get("cosmosConnectionString", "")
    if not connection_string:
        raise HTTPException(status_code=500, detail="Cosmos DB connection is not configured.")

    if _mongo_client is None:
        _mongo_client = MongoClient(connection_string)

    database_name = os.getenv("RAG_DATABASE_NAME", "ragdb")
    return _mongo_client[database_name]


def ensure_collection_indexes(collection: Any) -> None:
    global _indexes_bootstrapped

    if _indexes_bootstrapped:
        return

    collection.create_index(
        [("metadata.company_id", 1), ("metadata.user_id", 1)],
        name="tenant_scope_idx",
    )

    runtime_config = get_runtime_config()
    vector_dimensions = runtime_config.get("vectorDimensions", 1536)

    try:
        collection.database.command(
            {
                "createIndexes": collection.name,
                "indexes": [
                    {
                        "name": "vector_idx",
                        "key": {"vector": "cosmosSearch"},
                        "cosmosSearchOptions": {
                            "kind": "vector-ivf",
                            "numLists": 1,
                            "similarity": "COS",
                            "dimensions": vector_dimensions,
                        },
                    }
                ],
            }
        )
    except Exception as error:  # noqa: BLE001
        runtime_config["bootstrapWarnings"].append(str(error))

    _indexes_bootstrapped = True


def ensure_user_collection_indexes(collection: Any) -> None:
    global _user_indexes_bootstrapped

    if _user_indexes_bootstrapped:
        return

    collection.create_index([("user_id", 1)], unique=True, name="user_id_unique_idx")
    collection.create_index([("company_id", 1)], name="company_id_idx")
    _user_indexes_bootstrapped = True


def get_user_collection() -> Any:
    database = get_mongo_database()
    collection_name = os.getenv("RAG_USER_COLLECTION_NAME", "users")
    collection = database[collection_name]
    ensure_user_collection_indexes(collection)
    return collection


def resolve_tenant_context_with_app_roles(tenant_context: dict[str, Any]) -> dict[str, Any]:
    user_id = tenant_context.get("userId")
    principal = tenant_context.get("principal")
    if not user_id or not principal:
        return tenant_context

    user_collection = get_user_collection()
    now = datetime.now(tz=timezone.utc).isoformat()
    default_role = get_default_app_role()
    user_details = principal.get("userDetails") if isinstance(principal.get("userDetails"), str) else None
    identity_provider = principal.get("identityProvider") if isinstance(principal.get("identityProvider"), str) else None

    user_collection.update_one(
        {"user_id": user_id},
        {
            "$setOnInsert": {
                "user_id": user_id,
                "company_id": tenant_context.get("companyId"),
                "roles": [default_role],
                "createdAt": now,
                "createdBy": "jit-provisioner",
            },
            "$set": {
                "lastLoginAt": now,
                "user_details": user_details,
                "identity_provider": identity_provider,
                "company_id": tenant_context.get("companyId"),
            },
        },
        upsert=True,
    )

    user_doc = user_collection.find_one({"user_id": user_id}, {"_id": 0, "roles": 1}) or {}
    app_roles = user_doc.get("roles", []) if isinstance(user_doc.get("roles"), list) else []

    merged_context = dict(tenant_context)
    merged_context["appRoles"] = app_roles
    merged_context["roles"] = merge_principal_and_app_roles(tenant_context.get("roles", set()), app_roles)
    return merged_context


def get_mongo_collection() -> Any:
    database = get_mongo_database()
    collection_name = os.getenv("RAG_COLLECTION_NAME", "documents")
    collection = database[collection_name]
    ensure_collection_indexes(collection)
    return collection


def get_openai_client() -> AzureOpenAI:
    global _openai_client

    runtime_config = get_runtime_config()
    endpoint = runtime_config.get("openAiEndpoint", "")
    if not endpoint:
        raise HTTPException(status_code=500, detail="Azure OpenAI endpoint is not configured.")

    if _openai_client is None:
        token_provider = get_bearer_token_provider(DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default")
        _openai_client = AzureOpenAI(
            azure_endpoint=endpoint,
            azure_ad_token_provider=token_provider,
            api_version=os.getenv("AZURE_OPENAI_API_VERSION", "2024-06-01"),
        )

    return _openai_client


def create_embedding(text: str) -> list[float]:
    runtime_config = get_runtime_config()
    embedding_deployment = runtime_config.get("openAiEmbeddingDeployment", "")
    if not embedding_deployment:
        raise HTTPException(status_code=500, detail="Embedding deployment is not configured.")

    openai_client = get_openai_client()
    response = openai_client.embeddings.create(model=embedding_deployment, input=text)
    return response.data[0].embedding


@app.get("/health")
def health() -> dict[str, Any]:
    runtime_config = get_runtime_config()
    return {
        "status": "ok",
        "service": "azure-rag-api",
        "environment": os.getenv("AZURE_ENVIRONMENT", "local"),
        "keyVaultEnabled": runtime_config["keyVaultEnabled"],
    }


@app.get("/api/health")
def api_health() -> dict[str, Any]:
    return health()


@app.get("/api/me")
def me(x_ms_client_principal: str | None = Header(default=None, alias="X-MS-CLIENT-PRINCIPAL")) -> dict[str, Any]:
    principal = decode_client_principal(x_ms_client_principal)
    tenant_context = get_tenant_context(x_ms_client_principal)
    app_roles: list[str] = []

    if principal:
        try:
            tenant_context = resolve_tenant_context_with_app_roles(tenant_context)
            app_roles = tenant_context["appRoles"]
        except HTTPException:
            # Keep /api/me available even when DB config is incomplete.
            pass

    return {
        "authenticated": principal is not None,
        "roles": sorted(tenant_context["roles"]),
        "appRoles": sorted(app_roles),
        "principal": principal,
    }


@app.get("/api/config")
def config() -> dict[str, Any]:
    runtime_config = get_runtime_config()
    return {
        "environment": os.getenv("AZURE_ENVIRONMENT", "local"),
        "keyVaultConfigured": runtime_config["keyVaultEnabled"],
        "publicAppName": os.getenv("PUBLIC_APP_NAME", "azure-rag"),
        "hasCosmosConnection": bool(runtime_config["cosmosConnectionString"]),
        "hasOpenAiEndpoint": bool(runtime_config["openAiEndpoint"]),
        "openAiChatDeployment": runtime_config["openAiChatDeployment"],
        "openAiEmbeddingDeployment": runtime_config["openAiEmbeddingDeployment"],
        "requireAdminForIndex": runtime_config["requireAdminForIndex"],
        "allowAdminCrossCompany": runtime_config["allowAdminCrossCompany"],
        "secretLoadErrors": runtime_config["secretLoadErrors"],
        "bootstrapWarnings": runtime_config["bootstrapWarnings"],
    }


@app.post("/api/rag/index")
def index_document(
    payload: IndexDocumentRequest,
    x_ms_client_principal: str | None = Header(default=None, alias="X-MS-CLIENT-PRINCIPAL"),
) -> dict[str, Any]:
    runtime_config = get_runtime_config()
    tenant_context = resolve_tenant_context_with_app_roles(get_tenant_context(x_ms_client_principal))

    if runtime_config["requireTenantContext"] and not tenant_context["companyId"]:
        raise HTTPException(status_code=403, detail="Missing company context in principal claims.")

    if runtime_config["requireAdminForIndex"]:
        require_roles(
            tenant_context["roles"],
            {"administrator", "companyadmin"},
            "Indexing requires administrator or company admin role.",
        )

    requested_company_id = payload.metadata.get("company_id") if isinstance(payload.metadata.get("company_id"), str) else None
    effective_company_id = enforce_company_scope(
        tenant_context,
        requested_company_id,
        runtime_config,
        "index documents",
    )

    collection = get_mongo_collection()
    vector = create_embedding(payload.text)

    now = datetime.now(tz=timezone.utc).isoformat()
    metadata = dict(payload.metadata)
    if effective_company_id:
        metadata["company_id"] = effective_company_id
    if tenant_context["userId"]:
        metadata["user_id"] = tenant_context["userId"]

    document = {
        "_id": payload.document_id,
        "text": payload.text,
        "vector": vector,
        "metadata": metadata,
        "createdAt": now,
        "updatedAt": now,
    }

    collection.update_one(
        {"_id": payload.document_id},
        {
            "$set": document,
        },
        upsert=True,
    )

    return {
        "indexed": True,
        "documentId": payload.document_id,
        "embeddingDimensions": len(vector),
        "tenantContext": {
            "companyId": tenant_context["companyId"],
            "userId": tenant_context["userId"],
        },
    }


@app.post("/api/rag/chat")
def rag_chat(
    payload: ChatRequest,
    x_ms_client_principal: str | None = Header(default=None, alias="X-MS-CLIENT-PRINCIPAL"),
) -> dict[str, Any]:
    runtime_config = get_runtime_config()
    chat_deployment = runtime_config.get("openAiChatDeployment", "")
    if not chat_deployment:
        raise HTTPException(status_code=500, detail="Chat deployment is not configured.")

    tenant_context = resolve_tenant_context_with_app_roles(get_tenant_context(x_ms_client_principal))
    if runtime_config["requireTenantContext"] and not tenant_context["companyId"]:
        raise HTTPException(status_code=403, detail="Missing company context in principal claims.")

    question_vector = create_embedding(payload.question)
    collection = get_mongo_collection()

    scope_filter: dict[str, Any] = {}
    fallback_query: dict[str, Any] = {}
    if tenant_context["companyId"]:
        scope_filter["metadata.company_id"] = {"$eq": tenant_context["companyId"]}
        fallback_query["metadata.company_id"] = tenant_context["companyId"]
    if tenant_context["userId"]:
        scope_filter["metadata.user_id"] = {"$eq": tenant_context["userId"]}
        fallback_query["metadata.user_id"] = tenant_context["userId"]

    cosmos_search: dict[str, Any] = {
        "vector": question_vector,
        "path": "vector",
        "k": payload.top_k,
    }
    if scope_filter:
        cosmos_search["filter"] = scope_filter

    pipeline = [
        {
            "$search": {
                "cosmosSearch": cosmos_search,
                "returnStoredSource": True,
            }
        },
        {
            "$project": {
                "text": 1,
                "metadata": 1,
                "score": {"$meta": "searchScore"},
            }
        },
    ]

    try:
        results = list(collection.aggregate(pipeline))
    except Exception:  # noqa: BLE001
        results = list(collection.find(fallback_query, {"text": 1, "metadata": 1}).limit(payload.top_k))
    context_blocks = [item.get("text", "") for item in results]
    context_text = "\n\n".join(context_blocks) if context_blocks else "No matching documents were found."

    openai_client = get_openai_client()
    completion = openai_client.chat.completions.create(
        model=chat_deployment,
        messages=[
            {
                "role": "system",
                "content": "You are a helpful RAG assistant. Use provided context and be explicit when context is missing.",
            },
            {
                "role": "user",
                "content": f"Context:\n{context_text}\n\nQuestion:\n{payload.question}",
            },
        ],
        temperature=0.2,
    )

    answer = completion.choices[0].message.content if completion.choices else ""
    return {
        "answer": answer,
        "sources": results,
        "usedDocuments": len(results),
        "tenantContext": {
            "companyId": tenant_context["companyId"],
            "userId": tenant_context["userId"],
        },
    }


@app.post("/api/events/publish")
def publish_event(
    payload: PublishEventRequest,
    x_ms_client_principal: str | None = Header(default=None, alias="X-MS-CLIENT-PRINCIPAL"),
) -> dict[str, Any]:
    tenant_context = resolve_tenant_context_with_app_roles(get_tenant_context(x_ms_client_principal))
    require_roles(
        tenant_context["roles"],
        {"administrator", "companyadmin"},
        "Publishing events requires administrator or company admin role.",
    )

    requested_company_id = payload.data.get("company_id") if isinstance(payload.data.get("company_id"), str) else None
    effective_company_id = enforce_company_scope(
        tenant_context,
        requested_company_id,
        get_runtime_config(),
        "publish events",
    )
    if effective_company_id:
        payload.data["company_id"] = effective_company_id

    runtime_config = get_runtime_config()
    topic_endpoint = runtime_config.get("eventGridTopicEndpoint", "")
    topic_key = runtime_config.get("eventGridTopicKey", "")

    if not topic_endpoint or not topic_key:
        raise HTTPException(status_code=500, detail="Event Grid topic is not configured.")

    publisher = EventGridPublisherClient(topic_endpoint, AzureKeyCredential(topic_key))
    event = EventGridEvent(
        subject=payload.subject,
        event_type=payload.event_type,
        data_version="1.0",
        data=payload.data,
    )
    publisher.send([event])

    return {"published": True, "eventType": payload.event_type, "subject": payload.subject}


@app.post("/api/worker/eventgrid")
async def eventgrid_worker(request: Request, aeg_event_type: str | None = Header(default=None, alias="aeg-event-type")) -> Any:
    payload = await request.json()

    if aeg_event_type == "SubscriptionValidation":
        event = payload[0]
        validation_code = event["data"]["validationCode"]
        return {"validationResponse": validation_code}

    if not isinstance(payload, list):
        raise HTTPException(status_code=400, detail="Expected Event Grid event array payload.")

    processed: list[dict[str, Any]] = []
    for event in payload:
        processed.append(
            {
                "id": event.get("id"),
                "eventType": event.get("eventType"),
                "subject": event.get("subject"),
                "receivedAt": datetime.now(tz=timezone.utc).isoformat(),
            }
        )

    return {"processed": len(processed), "events": processed}


@app.get("/api/admin/tenant-context")
def admin_tenant_context(x_ms_client_principal: str | None = Header(default=None, alias="X-MS-CLIENT-PRINCIPAL")) -> dict[str, Any]:
    tenant_context = resolve_tenant_context_with_app_roles(get_tenant_context(x_ms_client_principal))
    require_roles(tenant_context["roles"], {"administrator"}, "Administrator role is required.")

    return {
        "companyId": tenant_context["companyId"],
        "userId": tenant_context["userId"],
        "roles": sorted(tenant_context["roles"]),
        "appRoles": sorted(tenant_context["appRoles"]),
    }


@app.get("/api/admin/users")
def admin_list_users(
    q: str | None = Query(default=None, max_length=128),
    limit: int = Query(default=8, ge=1, le=25),
    x_ms_client_principal: str | None = Header(default=None, alias="X-MS-CLIENT-PRINCIPAL"),
) -> dict[str, Any]:
    tenant_context = resolve_tenant_context_with_app_roles(get_tenant_context(x_ms_client_principal))
    require_roles(tenant_context["roles"], {"administrator"}, "Administrator role is required.")

    user_collection = get_user_collection()
    query: dict[str, Any] = {}

    normalized_q = q.strip() if isinstance(q, str) else ""
    if normalized_q:
        escaped = re.escape(normalized_q)
        regex = {"$regex": escaped, "$options": "i"}
        query = {
            "$or": [
                {"user_id": regex},
                {"user_details": regex},
                {"company_id": regex},
            ]
        }

    projection = {
        "_id": 0,
        "user_id": 1,
        "user_details": 1,
        "company_id": 1,
        "roles": 1,
        "lastLoginAt": 1,
    }
    cursor = user_collection.find(query, projection).sort("lastLoginAt", -1).limit(limit)
    users: list[dict[str, Any]] = []
    for item in cursor:
        roles = item.get("roles") if isinstance(item.get("roles"), list) else []
        users.append(
            {
                "userId": item.get("user_id"),
                "userDetails": item.get("user_details"),
                "companyId": item.get("company_id"),
                "appRoles": sorted([_normalize_role(role) for role in roles if isinstance(role, str)]),
                "lastLoginAt": item.get("lastLoginAt"),
            }
        )

    return {"users": users}


@app.put("/api/admin/users/{user_id}/roles")
def admin_update_user_roles(
    user_id: str,
    payload: UpdateUserRolesRequest,
    x_ms_client_principal: str | None = Header(default=None, alias="X-MS-CLIENT-PRINCIPAL"),
) -> dict[str, Any]:
    tenant_context = resolve_tenant_context_with_app_roles(get_tenant_context(x_ms_client_principal))
    require_roles(tenant_context["roles"], {"administrator"}, "Administrator role is required.")

    normalized_roles: list[str] = []
    for role in payload.roles:
        normalized = _normalize_role(role)
        if normalized and normalized != "authenticated" and normalized not in normalized_roles:
            normalized_roles.append(normalized)

    if not normalized_roles:
        normalized_roles = [get_default_app_role()]

    now = datetime.now(tz=timezone.utc).isoformat()
    user_collection = get_user_collection()
    user_collection.update_one(
        {"user_id": user_id},
        {
            "$set": {
                "roles": normalized_roles,
                "updatedAt": now,
                "updatedBy": tenant_context.get("userId"),
                "company_id": payload.company_id,
            },
            "$setOnInsert": {
                "user_id": user_id,
                "createdAt": now,
                "createdBy": tenant_context.get("userId"),
                "lastLoginAt": now,
            },
        },
        upsert=True,
    )

    return {
        "updated": True,
        "userId": user_id,
        "appRoles": normalized_roles,
        "companyId": payload.company_id,
    }
