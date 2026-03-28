#!/bin/bash
# Generic workspace setup — reads everything from workspace.json
# Supports both multi-repo and monorepo workspaces.

set -e

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspaces/$(basename "$(pwd)")}"
cd "$WORKSPACE_DIR"

START_TIME=$(date +%s)
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       WORKSPACE SETUP (postCreate)       ║"
echo "╚══════════════════════════════════════════╝"
echo "  Time: $(date '+%H:%M:%S')"
echo "  Dir:  $WORKSPACE_DIR"
echo ""

# ── Persist GITHUB_TOKEN and CODESPACE_NAME for postStartCommand (port visibility) ──
if [ -n "$GITHUB_TOKEN" ]; then
  echo "$GITHUB_TOKEN" > "$HOME/.gh-token"
  chmod 600 "$HOME/.gh-token"
  echo "[setup] ✓ GITHUB_TOKEN saved"
else
  echo "[setup] ✗ GITHUB_TOKEN not available — port visibility won't auto-set"
fi
if [ -n "$CODESPACE_NAME" ]; then
  echo "$CODESPACE_NAME" > "$HOME/.codespace-name"
  echo "[setup] ✓ CODESPACE_NAME saved: $CODESPACE_NAME"
else
  echo "[setup] ✗ CODESPACE_NAME not available"
fi

# ── Parse workspace.json ──
if [ ! -f "workspace.json" ]; then
  echo "ERROR: workspace.json not found in $WORKSPACE_DIR"
  exit 1
fi

WORKSPACE_NAME=$(jq -r '.name' workspace.json)
echo "Workspace: $WORKSPACE_NAME"

# ── Configure git auth ──
git config --global commit.gpgsign false
GIT_TOKEN="${WASHMEN_GITHUB_TOKEN:-$GITHUB_PAT}"
if [ -n "$GIT_TOKEN" ]; then
  # Configure auth for each git org in workspace.json
  for org in $(jq -r '.gitOrgs[]? // empty' workspace.json); do
    git config --global url."https://x-access-token:${GIT_TOKEN}@github.com/${org}/".insteadOf "https://github.com/${org}/"
    echo "Git auth configured for $org"
  done

  # npm auth for @washmen/ packages (if Washmen org is listed)
  if jq -e '.gitOrgs[]? | select(. == "Washmen")' workspace.json > /dev/null 2>&1; then
    echo "@washmen:registry=https://npm.pkg.github.com/" > ~/.npmrc
    echo "//npm.pkg.github.com/:_authToken=${GIT_TOKEN}" >> ~/.npmrc
    echo "npm auth configured for @washmen/ packages"
  fi
fi

# ── Clone repos ──
echo "Cloning repos..."

REPO_COUNT=$(jq '.repos | length' workspace.json)
for i in $(seq 0 $((REPO_COUNT - 1))); do
  NAME=$(jq -r ".repos[$i].name" workspace.json)
  URL=$(jq -r ".repos[$i].url // empty" workspace.json)
  BRANCH=$(jq -r ".repos[$i].branch // empty" workspace.json)
  CHECK_DIR=$(jq -r ".repos[$i].checkDir // \"package.json\"" workspace.json)

  if [ -z "$URL" ]; then
    echo "Skipping $NAME — no URL"
    continue
  fi

  # Check if already cloned
  if [ -e "$WORKSPACE_DIR/$NAME/$CHECK_DIR" ]; then
    echo "$NAME already cloned — skipping"
    continue
  fi

  # Private repos need token
  if echo "$URL" | grep -q "github.com" && [ -z "$GIT_TOKEN" ]; then
    IS_PRIVATE=$(jq -r ".repos[$i].isPrivate // false" workspace.json)
    if [ "$IS_PRIVATE" = "true" ]; then
      echo "Skipping $NAME — no git token for private repo"
      continue
    fi
  fi

  rm -rf "$NAME"
  CLONE_ARGS="--depth 1"
  [ -n "$BRANCH" ] && CLONE_ARGS="--branch $BRANCH $CLONE_ARGS"
  git clone "$URL" "$NAME" $CLONE_ARGS
  echo "Cloned $NAME${BRANCH:+ @ $BRANCH} ($(( $(date +%s) - START_TIME ))s)"
done

# Clone vibe-ui (always from GhrayebAli, public)
[ -f "vibe-ui/server-washmen.js" ] || (rm -rf vibe-ui && git clone https://github.com/GhrayebAli/vibe-ui.git vibe-ui && echo "Cloned vibe-ui")

# ── Install dependencies (skip if already installed) ──
export COREPACK_ENABLE_AUTO_PIN=0
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

for i in $(seq 0 $((REPO_COUNT - 1))); do
  NAME=$(jq -r ".repos[$i].name" workspace.json)
  PKG_MGR=$(jq -r ".repos[$i].packageManager // \"npm\"" workspace.json)
  NODE_OPTS=$(jq -r ".repos[$i].nodeOptions // empty" workspace.json)

  if [ ! -d "$WORKSPACE_DIR/$NAME" ]; then continue; fi
  if [ -d "$WORKSPACE_DIR/$NAME/node_modules" ]; then
    echo "$NAME deps already installed — skipping"
    continue
  fi

  echo "Installing $NAME dependencies ($PKG_MGR)..."
  (
    cd "$WORKSPACE_DIR/$NAME"
    if [ "$PKG_MGR" = "yarn" ]; then
      sudo corepack enable 2>/dev/null || true
      [ -n "$NODE_OPTS" ] && export NODE_OPTIONS="$NODE_OPTS"
      yarn install
    else
      npm install
    fi
  )
  echo "$NAME installed ($(( $(date +%s) - START_TIME ))s)"
done

# vibe-ui deps
if [ ! -d "$WORKSPACE_DIR/vibe-ui/node_modules" ]; then
  echo "Installing vibe-ui dependencies..."
  (cd "$WORKSPACE_DIR/vibe-ui" && npm install)
  echo "vibe-ui installed ($(( $(date +%s) - START_TIME ))s)"
fi

# ── Create .env files ──

if [ -n "$ANTHROPIC_API_KEY" ]; then
  echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" > "$WORKSPACE_DIR/vibe-ui/.env"
  echo "API key written to vibe-ui/.env"
fi

# ── Resolve per-repo envFiles (facility pattern: repos[i].envFiles) ──
RESOLVE_SCRIPT="$WORKSPACE_DIR/core/resolve-secrets.sh"

for i in $(seq 0 $((REPO_COUNT - 1))); do
  NAME=$(jq -r ".repos[$i].name" workspace.json)
  REPO_DIR="$WORKSPACE_DIR/$NAME"
  [ ! -d "$REPO_DIR" ] && continue

  for ENV_EXAMPLE in $(jq -r ".repos[$i].envFiles // {} | keys[]" workspace.json 2>/dev/null); do
    OUTPUT_NAME=$(jq -r ".repos[$i].envFiles[\"$ENV_EXAMPLE\"]" workspace.json)
    INPUT_PATH="$REPO_DIR/$ENV_EXAMPLE"
    OUTPUT_PATH="$REPO_DIR/$OUTPUT_NAME"

    if [ ! -f "$INPUT_PATH" ]; then
      echo "WARN: $NAME/$ENV_EXAMPLE not found — skipping"
      continue
    fi

    if grep -q "arn:aws:secretsmanager:" "$INPUT_PATH" 2>/dev/null && [ -f "$RESOLVE_SCRIPT" ]; then
      bash "$RESOLVE_SCRIPT" "$INPUT_PATH" "$OUTPUT_PATH"
    else
      cp "$INPUT_PATH" "$OUTPUT_PATH"
      echo "[setup] Copied $NAME/$ENV_EXAMPLE -> $(basename "$OUTPUT_NAME") (no secrets)"
    fi
  done
done

# ── Resolve top-level repoEnvFiles (ops pattern: repoEnvFiles at workspace root) ──
if jq -e '.repoEnvFiles' workspace.json > /dev/null 2>&1 && [ -f "$RESOLVE_SCRIPT" ]; then
  echo ""
  echo "Resolving backend secrets from AWS Secrets Manager..."
  for NAME in $(jq -r '.repoEnvFiles // {} | keys[]' workspace.json 2>/dev/null); do
    REPO_DIR="$WORKSPACE_DIR/$NAME"
    if [ ! -d "$REPO_DIR" ]; then continue; fi
    for ENV_EXAMPLE in $(jq -r ".repoEnvFiles[\"$NAME\"] | keys[]" workspace.json 2>/dev/null); do
      OUTPUT_NAME=$(jq -r ".repoEnvFiles[\"$NAME\"][\"$ENV_EXAMPLE\"]" workspace.json)
      INPUT_PATH="$REPO_DIR/$ENV_EXAMPLE"
      OUTPUT_PATH="$REPO_DIR/$OUTPUT_NAME"
      if [ ! -f "$INPUT_PATH" ]; then
        echo "WARN: $NAME/$ENV_EXAMPLE not found — skipping"
        continue
      fi
      if grep -q "arn:aws:secretsmanager:" "$INPUT_PATH" 2>/dev/null; then
        bash "$RESOLVE_SCRIPT" "$INPUT_PATH" "$OUTPUT_PATH"
      else
        cp "$INPUT_PATH" "$OUTPUT_PATH"
        echo "[setup] Copied $NAME/$ENV_EXAMPLE -> $OUTPUT_NAME (no secrets)"
      fi
    done
  done
fi

# ── Write inline .env files via envsubst (ops pattern: envFiles with string content) ──
if jq -e '.envFiles' workspace.json > /dev/null 2>&1; then
  ENVSUBST_VARS=""
  for var in GOOGLE_MAPS_KEY ALGOLIA_API_KEY SENTRY_DSN E2E_CLIENT_SECRET MUIX_LICENSE_KEY; do
    if [ -n "${!var}" ]; then
      ENVSUBST_VARS="$ENVSUBST_VARS \$$var"
    fi
  done

  for NAME in $(jq -r '.envFiles // {} | keys[]' workspace.json 2>/dev/null); do
    if [ ! -d "$WORKSPACE_DIR/$NAME" ]; then continue; fi
    for ENV_FILE in $(jq -r ".envFiles[\"$NAME\"] | keys[]" workspace.json 2>/dev/null); do
      CONTENT=$(jq -r ".envFiles[\"$NAME\"][\"$ENV_FILE\"]" workspace.json)
      if [ -n "$ENVSUBST_VARS" ]; then
        echo -e "$CONTENT" | envsubst "$ENVSUBST_VARS" > "$WORKSPACE_DIR/$NAME/$ENV_FILE"
      else
        echo -e "$CONTENT" > "$WORKSPACE_DIR/$NAME/$ENV_FILE"
      fi
      echo "Created $NAME/$ENV_FILE"
    done
  done
fi

# ── Patch frontend API URL for Codespace forwarded port ──
if [ "$CODESPACES" = "true" ] && [ -n "$CODESPACE_NAME" ]; then
  PATCH_REPO=$(jq -r '.frontendApiPatching.repo // empty' workspace.json)
  PATCH_FILE=$(jq -r '.frontendApiPatching.file // empty' workspace.json)
  PATCH_VAR=$(jq -r '.frontendApiPatching.envVar // empty' workspace.json)
  PATCH_PORT=$(jq -r '.frontendApiPatching.apiPort // empty' workspace.json)
  PATCH_SUFFIX=$(jq -r '.frontendApiPatching.suffix // "/"' workspace.json)

  if [ -n "$PATCH_REPO" ] && [ -n "$PATCH_VAR" ] && [ -n "$PATCH_PORT" ]; then
    API_URL="https://${CODESPACE_NAME}-${PATCH_PORT}.app.github.dev${PATCH_SUFFIX}"
    TARGET_FILE="$WORKSPACE_DIR/$PATCH_REPO/$PATCH_FILE"
    if [ -f "$TARGET_FILE" ]; then
      sed -i "s|${PATCH_VAR}=.*|${PATCH_VAR}=${API_URL}|" "$TARGET_FILE"
      echo "Patched ${PATCH_VAR}=${API_URL}"
    fi
  fi
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       SETUP COMPLETE — $(( $(date +%s) - START_TIME ))s              ║"
echo "╚══════════════════════════════════════════╝"
echo ""
