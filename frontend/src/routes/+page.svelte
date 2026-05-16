<script lang="ts">
  import { onDestroy, onMount } from 'svelte';
  import { PUBLIC_API_BASE_URL, PUBLIC_APP_NAME } from '$env/static/public';

  type HealthResponse = {
    status: string;
    service: string;
    environment: string;
  };

  type MeResponse = {
    clientPrincipal: {
      userDetails?: string;
      userId?: string;
      identityProvider?: string;
      userRoles?: string[];
    } | null;
  };

  type AdminTenantContextResponse = {
    companyId?: string | null;
    userId?: string | null;
    roles?: string[];
    appRoles?: string[];
  };

  type AdminUserSuggestion = {
    userId: string;
    userDetails?: string | null;
    companyId?: string | null;
    appRoles?: string[];
    lastLoginAt?: string | null;
  };

  let health: HealthResponse | null = null;
  let healthError: string | null = null;
  let me: MeResponse | null = null;
  let meError: string | null = null;
  let adminContext: AdminTenantContextResponse | null = null;
  let adminCheckError: string | null = null;
  let canManageRoles = false;

  let targetUserId = '';
  let targetRoles = 'member';
  let targetCompanyId = '';
  let roleUpdateMessage: string | null = null;
  let roleUpdateError: string | null = null;
  let isUpdatingRoles = false;
  let userSuggestions: AdminUserSuggestion[] = [];
  let suggestionError: string | null = null;
  let isLoadingSuggestions = false;

  let suggestionTimer: ReturnType<typeof setTimeout> | null = null;

  const apiBaseUrl = PUBLIC_API_BASE_URL || '/api';

  const parseRoles = (value: string): string[] =>
    value
      .split(',')
      .map((item) => item.trim())
      .filter(Boolean);

  const readErrorMessage = async (response: Response, fallback: string): Promise<string> => {
    try {
      const payload = (await response.json()) as { detail?: string };
      return payload.detail || fallback;
    } catch {
      return fallback;
    }
  };

  const fetchUserSuggestions = async (query: string) => {
    if (!canManageRoles) {
      userSuggestions = [];
      return;
    }

    const normalized = query.trim();
    if (normalized.length < 2) {
      userSuggestions = [];
      suggestionError = null;
      return;
    }

    isLoadingSuggestions = true;
    suggestionError = null;

    try {
      const response = await fetch(
        `${apiBaseUrl}/admin/users?q=${encodeURIComponent(normalized)}&limit=8`,
        {
          credentials: 'include'
        }
      );

      if (!response.ok) {
        suggestionError = await readErrorMessage(
          response,
          `User lookup failed with ${response.status}.`
        );
        userSuggestions = [];
        return;
      }

      const payload = (await response.json()) as { users?: AdminUserSuggestion[] };
      userSuggestions = payload.users || [];
    } catch (error) {
      suggestionError = error instanceof Error ? error.message : 'User lookup failed.';
      userSuggestions = [];
    } finally {
      isLoadingSuggestions = false;
    }
  };

  const onTargetUserInput = () => {
    if (suggestionTimer) {
      clearTimeout(suggestionTimer);
    }

    suggestionTimer = setTimeout(() => {
      fetchUserSuggestions(targetUserId);
    }, 220);
  };

  const selectSuggestion = (user: AdminUserSuggestion) => {
    targetUserId = user.userId;
    targetCompanyId = user.companyId || '';
    if (user.appRoles?.length) {
      targetRoles = user.appRoles.join(', ');
    }
    userSuggestions = [];
    suggestionError = null;
  };

  const updateUserRoles = async (event: SubmitEvent) => {
    event.preventDefault();
    roleUpdateMessage = null;
    roleUpdateError = null;

    const userId = targetUserId.trim();
    if (!userId) {
      roleUpdateError = 'User ID is required.';
      return;
    }

    isUpdatingRoles = true;

    try {
      const response = await fetch(`${apiBaseUrl}/admin/users/${encodeURIComponent(userId)}/roles`, {
        method: 'PUT',
        credentials: 'include',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          roles: parseRoles(targetRoles),
          company_id: targetCompanyId.trim() || null
        })
      });

      if (!response.ok) {
        roleUpdateError = await readErrorMessage(response, `Role update failed with ${response.status}.`);
        return;
      }

      const payload = (await response.json()) as {
        userId: string;
        appRoles: string[];
        companyId?: string | null;
      };

      roleUpdateMessage = `Updated ${payload.userId} roles: ${payload.appRoles.join(', ')}.`;
      targetCompanyId = payload.companyId || '';
      targetRoles = payload.appRoles.join(', ');
      fetchUserSuggestions(targetUserId);
    } catch (error) {
      roleUpdateError = error instanceof Error ? error.message : 'Role update failed.';
    } finally {
      isUpdatingRoles = false;
    }
  };

  onDestroy(() => {
    if (suggestionTimer) {
      clearTimeout(suggestionTimer);
    }
  });

  onMount(async () => {
    try {
      const response = await fetch(`${apiBaseUrl}/health`);
      if (!response.ok) {
        throw new Error(`Health check failed with ${response.status}`);
      }

      health = (await response.json()) as HealthResponse;
    } catch (error) {
      healthError = error instanceof Error ? error.message : 'Unknown connection error.';
    }

    try {
      const response = await fetch('/.auth/me', {
        credentials: 'include'
      });
      if (!response.ok) {
        throw new Error(`/.auth/me failed with ${response.status}`);
      }

      me = (await response.json()) as MeResponse;
    } catch (error) {
      meError =
        error instanceof Error ? error.message : 'Unable to determine authenticated principal state.';
    }

    if (!me?.clientPrincipal) {
      return;
    }

    try {
      const response = await fetch(`${apiBaseUrl}/admin/tenant-context`, {
        credentials: 'include'
      });

      if (response.status === 401 || response.status === 403) {
        return;
      }

      if (!response.ok) {
        throw new Error(`Admin context check failed with ${response.status}`);
      }

      adminContext = (await response.json()) as AdminTenantContextResponse;
      canManageRoles = Boolean(adminContext.roles?.includes('administrator'));
    } catch (error) {
      adminCheckError =
        error instanceof Error ? error.message : 'Unable to verify administrator capabilities.';
    }
  });
</script>

<svelte:head>
  <title>{PUBLIC_APP_NAME}</title>
  <meta
    name="description"
    content="Azure RAG starter with SvelteKit, FastAPI, Bicep, and GitHub Actions"
  />
</svelte:head>

<main class="shell">
  <section class="hero">
    <div class="eyebrow">Azure RAG starter</div>
    <h1>Local development first, Azure dev and prod ready.</h1>
    <p>
      SvelteKit on the edge, FastAPI for orchestration, and Bicep plus GitHub Actions for repeatable deployments.
    </p>

    <div class="actions">
      <a href="https://learn.microsoft.com/azure/static-web-apps/" target="_blank" rel="noreferrer">Static Web Apps</a>
      <a href="https://learn.microsoft.com/azure/container-apps/" target="_blank" rel="noreferrer">Container Apps</a>
      <a href="/.auth/login/aad?post_login_redirect_uri=/" data-sveltekit-reload>Login with Entra</a>
      <a href="/.auth/logout?post_logout_redirect_uri=/" data-sveltekit-reload>Logout</a>
    </div>
  </section>

  <section class="grid">
    <article class="card">
      <h2>Backend status</h2>
      {#if health}
        <dl>
          <div>
            <dt>Status</dt>
            <dd>{health.status}</dd>
          </div>
          <div>
            <dt>Service</dt>
            <dd>{health.service}</dd>
          </div>
          <div>
            <dt>Environment</dt>
            <dd>{health.environment}</dd>
          </div>
        </dl>
      {:else if healthError}
        <p class="error">{healthError}</p>
      {:else}
        <p>Connecting to the API...</p>
      {/if}
    </article>

    <article class="card accent">
      <h2>Deployment shape</h2>
      <ul>
        <li>One dev (test) and one prod environment</li>
        <li>Managed identity and Key Vault from day one</li>
        <li>GitHub Actions for infra and app delivery</li>
      </ul>
    </article>

    <article class="card">
      <h2>Auth status (SWA Entra)</h2>
      {#if me}
        {@const principal = me.clientPrincipal}
        <dl>
          <div>
            <dt>Authenticated</dt>
            <dd>{principal ? 'yes' : 'no'}</dd>
          </div>
          <div>
            <dt>User</dt>
            <dd>{principal?.userDetails ?? 'anonymous'}</dd>
          </div>
          <div>
            <dt>Identity provider</dt>
            <dd>{principal?.identityProvider ?? 'n/a'}</dd>
          </div>
          <div>
            <dt>Roles</dt>
            <dd>{principal?.userRoles?.length ? principal.userRoles.join(', ') : 'none'}</dd>
          </div>
        </dl>
      {:else if meError}
        <p class="error">{meError}</p>
      {:else}
        <p>Loading principal information...</p>
      {/if}
      <p class="hint">Use this panel after login to verify claims and role mapping.</p>
      {#if adminCheckError}
        <p class="hint error">{adminCheckError}</p>
      {/if}
    </article>

    {#if canManageRoles}
      <article class="card admin">
        <h2>Admin: user role management</h2>
        <p class="hint">
          Signed in as {adminContext?.userId ?? 'administrator'}.
          Update app roles for a user without leaving this page.
        </p>

        <form class="admin-form" on:submit={updateUserRoles}>
          <label>
            <span>Target user ID</span>
            <input
              bind:value={targetUserId}
              placeholder="oid-or-sub"
              required
              list="admin-user-suggestions"
              on:input={onTargetUserInput}
            />
            <datalist id="admin-user-suggestions">
              {#each userSuggestions as user}
                <option value={user.userId}>{user.userDetails || ''}</option>
              {/each}
            </datalist>
          </label>

          {#if isLoadingSuggestions}
            <p class="hint">Searching users...</p>
          {/if}
          {#if suggestionError}
            <p class="error">{suggestionError}</p>
          {/if}
          {#if userSuggestions.length}
            <div class="suggestions" aria-label="User suggestions">
              {#each userSuggestions as user}
                <button type="button" class="suggestion-item" on:click={() => selectSuggestion(user)}>
                  <strong>{user.userDetails || user.userId}</strong>
                  <span>{user.userId}</span>
                  <span>{user.companyId || 'no company'}</span>
                </button>
              {/each}
            </div>
          {/if}

          <label>
            <span>App roles (comma-separated)</span>
            <input bind:value={targetRoles} placeholder="member, companyadmin" />
          </label>

          <label>
            <span>Company ID (optional)</span>
            <input bind:value={targetCompanyId} placeholder="company-123" />
          </label>

          <button type="submit" disabled={isUpdatingRoles}>
            {isUpdatingRoles ? 'Updating...' : 'Update roles'}
          </button>
        </form>

        {#if roleUpdateMessage}
          <p class="ok">{roleUpdateMessage}</p>
        {/if}
        {#if roleUpdateError}
          <p class="error">{roleUpdateError}</p>
        {/if}
      </article>
    {/if}
  </section>
</main>

<style>
  :global(body) {
    margin: 0;
    font-family: 'Space Grotesk', 'Aptos', 'Segoe UI', sans-serif;
    background:
      radial-gradient(circle at top left, rgba(14, 165, 233, 0.16), transparent 30%),
      radial-gradient(circle at top right, rgba(245, 158, 11, 0.14), transparent 28%),
      linear-gradient(180deg, #f8fafc 0%, #eef2f7 100%);
    color: #0f172a;
  }

  .shell {
    min-height: 100vh;
    display: grid;
    gap: 2rem;
    padding: 4rem clamp(1.25rem, 4vw, 4rem);
    max-width: 1120px;
    margin: 0 auto;
    box-sizing: border-box;
  }

  .hero {
    background: rgba(255, 255, 255, 0.72);
    backdrop-filter: blur(18px);
    border: 1px solid rgba(15, 23, 42, 0.08);
    border-radius: 28px;
    padding: clamp(1.5rem, 4vw, 3rem);
    box-shadow: 0 24px 60px rgba(15, 23, 42, 0.08);
  }

  .eyebrow {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.35rem 0.75rem;
    border-radius: 999px;
    background: rgba(14, 165, 233, 0.12);
    color: #0369a1;
    font-size: 0.85rem;
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  h1 {
    margin: 1rem 0 0.75rem;
    font-size: clamp(2.6rem, 6vw, 4.8rem);
    line-height: 0.96;
    letter-spacing: -0.06em;
    max-width: 12ch;
  }

  p {
    margin: 0;
    font-size: 1.05rem;
    line-height: 1.65;
    max-width: 64ch;
    color: #334155;
  }

  .actions {
    display: flex;
    gap: 0.75rem;
    flex-wrap: wrap;
    margin-top: 1.5rem;
  }

  .actions a {
    text-decoration: none;
    color: #0f172a;
    font-weight: 700;
    padding: 0.8rem 1rem;
    border-radius: 999px;
    background: #ffffff;
    border: 1px solid rgba(15, 23, 42, 0.12);
  }

  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 1rem;
  }

  .card {
    background: rgba(255, 255, 255, 0.8);
    border: 1px solid rgba(15, 23, 42, 0.08);
    border-radius: 24px;
    padding: 1.5rem;
    box-shadow: 0 18px 40px rgba(15, 23, 42, 0.06);
  }

  .card.accent {
    background: linear-gradient(180deg, rgba(14, 165, 233, 0.14), rgba(255, 255, 255, 0.92));
  }

  .card.admin {
    border-color: rgba(2, 132, 199, 0.35);
    background:
      radial-gradient(circle at top right, rgba(2, 132, 199, 0.12), transparent 45%),
      rgba(255, 255, 255, 0.9);
  }

  h2 {
    margin: 0 0 1rem;
    font-size: 1.15rem;
  }

  dl {
    margin: 0;
    display: grid;
    gap: 0.75rem;
  }

  dt {
    font-size: 0.8rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: #64748b;
  }

  dd {
    margin: 0.2rem 0 0;
    font-size: 1.05rem;
    font-weight: 700;
  }

  ul {
    margin: 0;
    padding-left: 1.2rem;
    color: #334155;
    line-height: 1.8;
  }

  .error {
    color: #b91c1c;
    font-weight: 600;
  }

  .hint {
    margin-top: 1rem;
    color: #475569;
    font-size: 0.92rem;
  }

  .admin-form {
    margin-top: 1rem;
    display: grid;
    gap: 0.75rem;
  }

  .admin-form label {
    display: grid;
    gap: 0.3rem;
  }

  .admin-form span {
    font-size: 0.82rem;
    color: #475569;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }

  .admin-form input {
    border: 1px solid rgba(15, 23, 42, 0.18);
    border-radius: 12px;
    padding: 0.7rem 0.8rem;
    font-size: 0.95rem;
    font-family: inherit;
    color: #0f172a;
    background: rgba(255, 255, 255, 0.96);
  }

  .admin-form button {
    margin-top: 0.4rem;
    width: fit-content;
    border: 0;
    border-radius: 999px;
    padding: 0.65rem 1rem;
    background: #0284c7;
    color: white;
    font-weight: 700;
    cursor: pointer;
  }

  .admin-form button:disabled {
    opacity: 0.7;
    cursor: progress;
  }

  .suggestions {
    display: grid;
    gap: 0.5rem;
    margin: 0.3rem 0 0.5rem;
  }

  .suggestion-item {
    border: 1px solid rgba(15, 23, 42, 0.14);
    background: rgba(248, 250, 252, 0.95);
    border-radius: 12px;
    padding: 0.55rem 0.7rem;
    text-align: left;
    cursor: pointer;
    display: grid;
    gap: 0.12rem;
  }

  .suggestion-item strong {
    font-size: 0.9rem;
  }

  .suggestion-item span {
    font-size: 0.8rem;
    color: #475569;
  }

  .ok {
    margin-top: 0.9rem;
    color: #047857;
    font-weight: 600;
  }
</style>
