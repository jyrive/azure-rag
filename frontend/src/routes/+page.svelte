<script lang="ts">
  import { onMount } from 'svelte';
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

  let health: HealthResponse | null = null;
  let healthError: string | null = null;
  let me: MeResponse | null = null;
  let meError: string | null = null;

  onMount(async () => {
    if (!PUBLIC_API_BASE_URL) {
      healthError = 'PUBLIC_API_BASE_URL is not configured.';
    } else {
      try {
        const response = await fetch(`${PUBLIC_API_BASE_URL}/health`);
        if (!response.ok) {
          throw new Error(`Health check failed with ${response.status}`);
        }

        health = (await response.json()) as HealthResponse;
      } catch (error) {
        healthError = error instanceof Error ? error.message : 'Unknown connection error.';
      }
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
      <a href="/.auth/login/aad?post_login_redirect_uri=/">Login with Entra</a>
      <a href="/.auth/logout?post_logout_redirect_uri=/">Logout</a>
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
    </article>
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
</style>
