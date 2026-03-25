# Washmen Codespace Setup Guide

A structured guide for setting up a new Codespace workspace with VPN connectivity, backend services, and frontend—based on lessons learned from the washmen-ops-workspace setup.

---

## Prerequisites

### 1. GitHub Access
- GitHub account with Codespaces enabled
- `gh` CLI authenticated (`gh auth login`)
- Repository created under your GitHub org/user

### 2. VPN Configuration
- OpenVPN-compatible `.ovpn` config file from your DevOps team
- The `.ovpn` file must contain only PEM-encoded blocks (no human-readable cert dumps)
- Private key extracted separately for storage as a Codespace secret

### 3. Codespace Secrets (repo-level)
Set these **before** creating the Codespace. Go to: Repo Settings > Secrets and variables > Codespaces.

| Secret | Purpose | How to get |
|---|---|---|
| `WASHMEN_GITHUB_TOKEN` | Git auth for private repos + npm packages | GitHub PAT with `repo` scope |
| `ANTHROPIC_API_KEY` | Claude/vibe-ui AI features | Anthropic dashboard |
| `VPN_PRIVATE_KEY` | OpenVPN private key (full PEM with headers) | DevOps team |
| `AWS_ACCESS_KEY_ID` | DynamoDB, S3, SNS access | `~/.aws/credentials` or IAM console |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key | Same as above |
| `VIEWS_PGPASSWORD` | PostgreSQL password | DevOps team |
| `REDSHIFT_WAREHOUSE_DB_PASSWORD` | Redshift password | DevOps team |
| `INTERNAL_USER_AUTH_SALT` | Auth password hashing | DevOps team |
| `INTERCOM_ACCESS_TOKEN` | Intercom API | Intercom dashboard |
| `GOOGLE_PLACES_API_KEY` | Google Places API | Google Cloud Console |
| `GOOGLE_MAPS_KEY` | Google Maps (frontend) | Google Cloud Console |
| `ALGOLIA_APP_ID` | Algolia search (frontend) | Algolia dashboard |
| `ALGOLIA_API_KEY` | Algolia search key (frontend) | Algolia dashboard |
| `SENTRY_DSN` | Error reporting | Sentry dashboard |
| `E2E_CLIENT_ID` | Cognito machine auth client ID | AWS Cognito console |
| `E2E_CLIENT_SECRET` | Cognito machine auth client secret | AWS Cognito console |

**Important:** All secrets must be set before the first `gh codespace create`. The `postCreateCommand` runs once on creation and uses these secrets to generate `.env` files. Missing secrets = empty values in `.env` files.

### 4. Infrastructure Requirements
- Backend services accessible via VPN (load balancer, databases, Redis, DynamoDB)
- Cognito user pool configured with machine-to-machine auth
- At least one test user in DynamoDB (`ops_users` table)

---

## Architecture Overview

```
Browser (your machine)
  │
  ├── :3000 (ops-frontend) ──── public, Codespace forwarded URL
  ├── :4000 (vibe-ui) ────────── public, Codespace forwarded URL
  ├── :1339 (internal-public-api) ── public, for browser API calls
  └── :2339 (srv-internal-user-backend) ── private, internal only
          │
          └── VPN tunnel ──── internal LB, Redis, DynamoDB, RDS, etc.
```

### Service Communication Flow
```
Browser → :3000 (frontend) → REACT_APP_INTERNAL_API_OPS → :1339 (public-api)
  :1339 → SRV_INTERNAL_BACKEND_URL → :2339 (user-backend, local)
  :1339 → SRV_*_BACKEND_URL → internal LB (other microservices via VPN)
  :2339 → DynamoDB, PostgreSQL, Redis (via VPN)
```

### Auth Flow
```
1. Browser → POST :3000/__dev-machine-auth (webpack dev server proxy)
2. Dev server → POST dev-ops-auth.washmen.com/oauth2/token (Cognito)
3. Dev server → POST :1339/auth/testing-callback (local public-api)
4. Public-api → :2339/users/list-by-email (local user-backend → DynamoDB)
5. Public-api → creates AuthToken in memory store
6. Browser gets authToken, uses it for all subsequent API calls to :1339
```

---

## Common Pitfalls & Solutions

### 1. CWD Pollution in Shell Scripts
**Problem:** `cd` into a repo dir for `npm install` leaves the shell in the wrong directory for the next iteration.
**Solution:** Always use subshells: `(cd "$DIR" && npm install)` — the parentheses isolate the `cd`.

### 2. Secrets Not Available in SSH Sessions
**Problem:** `gh codespace ssh` does not inject Codespace secrets into the environment.
**Solution:** Secrets and `GITHUB_TOKEN` are only available during lifecycle commands (`postCreateCommand`, `postStartCommand`). Generate all config files during `postCreateCommand`. The `start.sh` script is self-healing — it checks for missing deps and installs them, so manually re-running setup is rarely needed.

### 3. `envsubst` Expands Too Much
**Problem:** `envsubst` with no args replaces ALL `$VAR` patterns, including `$npm_package_version`.
**Solution:** Pass a specific variable list: `envsubst "$VAR1 $VAR2"`. Only expand known Codespace secrets.

### 4. Background Processes Killed on Lifecycle Exit
**Problem:** `nohup cmd &` in `postStartCommand` — the background process gets reaped when the lifecycle shell exits.
**Solution:** Run the main script in foreground and use `wait` at the end to keep it alive:
```json
"postStartCommand": "bash .devcontainer/start-openvpn.sh; bash .devcontainer/start.sh"
```
Where `start.sh` launches services with `&` and ends with `wait`.

### 5. Trailing Slashes in Service URLs
**Problem:** `SRV_INTERNAL_BACKEND_URL=http://localhost:2339/` + `/users/list` = `//users/list` → 404.
**Solution:** Never include trailing slashes in service URLs. The hooks append paths with leading slashes.

### 6. Browser Can't Reach localhost Ports
**Problem:** Frontend runs in the browser on your machine. `REACT_APP_INTERNAL_API_OPS=http://localhost:1339` doesn't work — nothing runs on your machine's port 1339.
**Solution:** Use the Codespace forwarded URL: `https://<codespace-name>-1339.app.github.dev/`. Auto-patch in `setup.sh`:
```bash
if [ "$CODESPACES" = "true" ] && [ -n "$CODESPACE_NAME" ]; then
  API_URL="https://${CODESPACE_NAME}-1339.app.github.dev"
  sed -i "s|REACT_APP_INTERNAL_API_OPS=.*|REACT_APP_INTERNAL_API_OPS=${API_URL}/|" .env.development
fi
```
Port must be set to **public** visibility.

### 7. E2E Auth Must Hit Local API
**Problem:** `REACT_APP_E2E_INTERNAL_API_OPS` pointing to external dev API creates AuthTokens there, but the local public-api doesn't recognize them.
**Solution:** Point to `http://localhost:1339` — the `setupProxy.js` call is server-side (runs inside the Codespace), so localhost is reachable.

### 8. `ENABLE_SENTRY` Crash
**Problem:** `process.env.ENABLE_SENTRY.toUpperCase()` crashes when the env var is unset.
**Solution:** Set `ENABLE_SENTRY=false` in both backend `.env` files.

### 9. Corepack/Yarn Hangs
**Problem:** First `yarn install` hangs because corepack hasn't downloaded the Yarn binary.
**Solution:** Pre-activate in `postCreateCommand`:
```
sudo corepack enable && corepack prepare yarn@3.2.4 --activate
```

### 10. VPN Config Template
**Problem:** `.ovpn` file with human-readable cert dump before the PEM block causes OpenVPN parse failure.
**Solution:** Only include PEM-encoded blocks (`-----BEGIN/END CERTIFICATE-----`) in the template. Remove `openssl x509 -text` output.

---

## Step-by-Step: Adding a New Backend Service

1. **Explore the repo** — identify:
   - Framework (Sails.js, Express, etc.)
   - Port (check `config/env/development.js`)
   - Package manager (`npm` or `yarn`)
   - Default branch (`main` or `master`)

2. **Identify ALL env vars** — check:
   - `config/` directory for `process.env.*` references
   - `node_modules/@washmen/sails-hook-*` for `process.env.SRV_*` service URLs
   - `app.js` and `sentry-instrument.js` for startup requirements
   - `api/helpers/` for database/Redis connection configs

3. **Classify vars** as secrets vs config:
   - Secrets: passwords, API keys, access tokens, salts → Codespace secrets
   - Config: URLs, ports, region names, feature flags → `workspace.json` envFiles

4. **Test startup blockers** — identify what crashes the service:
   - Missing database credentials → service won't lift
   - Missing Redis host → ORM init fails
   - Missing `ENABLE_SENTRY` → error handler crashes (masking real errors)
   - Missing AWS credentials → DynamoDB/S3/SNS calls fail

5. **Update workspace.json:**
   - Add repo to `repos` array with port, dev command, branch
   - Add `.env` to `envFiles` with all vars (use `$SECRET_NAME` for secrets)
   - No trailing slashes on service URLs

6. **Update devcontainer.json:**
   - Add port to `forwardPorts`
   - Add port to `portsAttributes`
   - Add any new secrets to `secrets`

7. **Update setup.sh:**
   - Add new secret names to the `envsubst` variable list

8. **Update .gitignore:**
   - Add the new repo directory

9. **Test** — create a fresh Codespace and verify:
   - Deps install without hanging
   - `.env` files have expanded secrets
   - Service starts and listens on its port
   - Health checks pass
   - Auth flow works end-to-end

---

## How Codespace Startup Works

Every Codespace lifecycle event (create, start, restart, rebuild) is handled automatically by two scripts. No manual intervention is needed.

### Lifecycle Phases

| Phase | Script | Runs when | Has secrets? | Has GITHUB_TOKEN? |
|---|---|---|---|---|
| `postCreateCommand` | `setup.sh` | Create, full rebuild | Yes | Yes |
| `postStartCommand` | `start-openvpn.sh` + `start.sh` | Every start/restart | No (files persist) | Yes |

### Phase 1: First-Time Setup (`setup.sh` — runs once)

1. **Configure git auth** — sets up token-based auth for each git org in `workspace.json`
2. **Configure npm auth** — writes `.npmrc` for `@washmen/` scoped packages
3. **Clone repos** — clones all repos from `workspace.json` (skips if already cloned)
4. **Install dependencies** — runs `npm install` or `yarn install` per repo (skips if `node_modules` exists)
5. **Generate `.env` files** — reads `envFiles` from `workspace.json`, substitutes Codespace secrets via `envsubst`
6. **Patch frontend API URL** — replaces `localhost:1339` with the Codespace forwarded URL for browser API calls
7. **Generate VPN config** — builds `.ovpn` file from template + `VPN_PRIVATE_KEY` secret

### Phase 2: VPN (`start-openvpn.sh` — every start)

1. **Start OpenVPN** — connects to Washmen internal network
2. **Wait for tunnel** — polls `tun0` interface until connected (up to 30s)
3. **Verify connectivity** — pings the internal load balancer to confirm VPN is up

The VPN is required for backend services to reach databases (RDS, DynamoDB), Redis, and other microservices on the internal network.

### Phase 3: Service Startup (`start.sh` — every start)

This script is **self-healing** — it handles any state (fresh create, restart, crashed services, missing deps).

1. **Check & install deps** — for each repo, if `node_modules` is missing, installs automatically
2. **Restore active branch** — reads `.active-branch` file and checks out the last-used feature branch
3. **Clear old logs** — truncates `/tmp/*.log` for clean output
4. **Kill stale processes** — kills any leftover processes on configured ports
5. **Start all services** — launches each service from `workspace.json` in the background using its `dev` command
6. **Start vibe-ui** — launches on port 4000 with the Anthropic API key
7. **Health check** — waits up to 90 seconds, polling every 3 seconds until all ports are listening. Reports status per port (✓ or ✗)
8. **Set port visibility** — reads `devcontainer.json` and sets ports marked `"visibility": "public"` via `gh` CLI. Core services with database access stay **private**

### Port Visibility

| Port | Service | Visibility | Why |
|---|---|---|---|
| 4000 | vibe-ui | **public** | Main UI, opened in browser |
| 3000 | ops-frontend | **public** | React app, loaded in preview iframe |
| 1339 | internal-public-api | **public** | API gateway, called from browser JS |
| 2339 | srv-internal-user-backend | **private** | Has direct database access |

Port visibility is configured in `devcontainer.json` under `portsAttributes`. The `start.sh` script enforces it on every startup because Codespaces resets visibility to private on restart.

### What Handles Each Scenario

| Scenario | What happens |
|---|---|
| **Create** | `setup.sh` → clone, install, generate .env → `start.sh` → VPN, services, health, ports |
| **Stop/Start** | `start.sh` only → VPN, services, health, ports (deps & .env already on disk) |
| **Restart** | Same as stop/start |
| **Rebuild** | Same as create (fresh container) |
| **Branch switch** | vibe-ui handles: checkout, dep check, smart restart (skips unchanged repos) |
| **Git reset/pull** | No impact — startup doesn't depend on flag files or git state |

---

## Quick Reference: Debugging

```bash
# Check VPN
cat .devcontainer/openvpn-tmp/openvpn.log

# Check service logs
tail -f /tmp/internal-public-api.log
tail -f /tmp/srv-internal-user-backend.log
tail -f /tmp/ops-frontend.log
tail -f /tmp/vibe.log

# Check ports
lsof -i :1339 -sTCP:LISTEN
lsof -i :2339 -sTCP:LISTEN
lsof -i :3000 -sTCP:LISTEN
lsof -i :4000 -sTCP:LISTEN

# Test auth flow
curl -s -X POST http://localhost:3000/__dev-machine-auth | jq .

# Test API with token
TOKEN=$(curl -s -X POST http://localhost:3000/__dev-machine-auth | jq -r .authToken)
curl -s "http://localhost:1339/customers?page=1&size=2" -H "Authorization: Bearer $TOKEN" | jq .
```
