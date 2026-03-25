# workspace-core

Shared codespace infrastructure for all Washmen workspaces. Added as a git submodule in each workspace repo.

## Contents

| File | Purpose |
|---|---|
| `setup.sh` | First-time codespace setup: clone repos, install deps, generate .env files |
| `start.sh` | Service startup on every start/restart: self-healing deps, health check, port visibility |
| `create-workspace.sh` | Scaffolding tool to generate a new workspace repo |
| `docs/codespace-setup-guide.md` | Full guide: prerequisites, architecture, startup flow, debugging |
| `docs/env-secrets-spec.md` | Secrets and environment variable architecture |

## Usage

### In a workspace repo

```bash
# Add as submodule (one-time)
git submodule add https://github.com/GhrayebAli/workspace-core.git core

# In devcontainer.json, reference the scripts:
# "postCreateCommand": "bash core/setup.sh"
# "postStartCommand": "bash core/start.sh"
```

### Update all workspaces

After making changes to this repo:

```bash
# In each workspace repo:
cd core && git pull origin main && cd ..
git add core && git commit -m "Update workspace-core" && git push
```

### Create a new workspace

```bash
bash core/create-workspace.sh \
  --name "My Workspace" \
  --owner GhrayebAli \
  --dir ./my-workspace \
  --repo https://github.com/Org/frontend:3000:frontend:npm:my-frontend \
  --repo https://github.com/Org/api:1337:backend:npm
```

## Design Principles

- **Self-healing**: `start.sh` checks for missing deps and installs them. No flag files.
- **Generic**: Scripts read everything from `workspace.json` — no hardcoded repo names or ports.
- **Secure**: Core services with DB access stay private. Only user-facing ports are set public.
- **Zero intervention**: Create → stop → start → restart all work automatically.
