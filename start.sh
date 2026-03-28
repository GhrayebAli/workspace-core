#!/bin/bash
# Generic service startup — reads everything from workspace.json
# Supports both multi-repo (background) and monorepo (foreground) workspaces.
# Self-healing: installs missing deps, re-resolves env, starts services, verifies health, sets ports public.

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspaces/$(basename "$(pwd)")}"
cd "$WORKSPACE_DIR"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       SERVICE STARTUP (postStart)        ║"
echo "╚══════════════════════════════════════════╝"
echo "  Time: $(date '+%H:%M:%S')"
echo "  Dir:  $WORKSPACE_DIR"
echo ""

if [ ! -f "workspace.json" ]; then
  echo "[start] ✗ workspace.json not found"
  exit 1
fi

REPO_COUNT=$(jq '.repos | length' workspace.json)
STARTUP_MODE=$(jq -r '.startup // "background"' workspace.json)

# ── Collect all ports for health check later ──
ALL_PORTS="4000"
for i in $(seq 0 $((REPO_COUNT - 1))); do
  PORT=$(jq -r ".repos[$i].port // empty" workspace.json)
  [ -n "$PORT" ] && ALL_PORTS="$ALL_PORTS $PORT"
  # Also collect from ports array (monorepo with multiple services)
  for p in $(jq -r ".repos[$i].ports // [] | .[]" workspace.json 2>/dev/null); do
    echo "$ALL_PORTS" | grep -qw "$p" || ALL_PORTS="$ALL_PORTS $p"
  done
done

# ── Ensure deps exist (self-healing) ──
export COREPACK_ENABLE_AUTO_PIN=0
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

echo "[deps] Checking dependencies..."
for i in $(seq 0 $((REPO_COUNT - 1))); do
  NAME=$(jq -r ".repos[$i].name" workspace.json)
  PKG_MGR=$(jq -r ".repos[$i].packageManager // \"npm\"" workspace.json)
  NODE_OPTS=$(jq -r ".repos[$i].nodeOptions // empty" workspace.json)

  if [ -d "$WORKSPACE_DIR/$NAME" ] && [ ! -d "$WORKSPACE_DIR/$NAME/node_modules" ]; then
    echo "[deps] ⏳ $NAME missing — installing ($PKG_MGR)..."
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
  fi
done

if [ -d "$WORKSPACE_DIR/vibe-ui" ] && [ ! -d "$WORKSPACE_DIR/vibe-ui/node_modules" ]; then
  echo "[deps] ⏳ vibe-ui missing — installing..."
  (cd "$WORKSPACE_DIR/vibe-ui" && npm install)
fi
echo "[deps] ✓ All dependencies ready"

# ── Restore active branch ──
if [ -f "$WORKSPACE_DIR/.active-branch" ]; then
  BRANCH=$(cat "$WORKSPACE_DIR/.active-branch")
  echo "[branch] Restoring: $BRANCH"
  for i in $(seq 0 $((REPO_COUNT - 1))); do
    NAME=$(jq -r ".repos[$i].name" workspace.json)
    git -C "$WORKSPACE_DIR/$NAME" checkout "$BRANCH" 2>/dev/null || true
  done
fi

# ── Regenerate .env files if missing ──

# Per-repo envFiles (facility pattern: repos[i].envFiles)
RESOLVE_SCRIPT="$WORKSPACE_DIR/core/resolve-secrets.sh"
for i in $(seq 0 $((REPO_COUNT - 1))); do
  NAME=$(jq -r ".repos[$i].name" workspace.json)
  REPO_DIR="$WORKSPACE_DIR/$NAME"
  [ ! -d "$REPO_DIR" ] && continue

  for ENV_EXAMPLE in $(jq -r ".repos[$i].envFiles // {} | keys[]" workspace.json 2>/dev/null); do
    OUTPUT_NAME=$(jq -r ".repos[$i].envFiles[\"$ENV_EXAMPLE\"]" workspace.json)
    OUTPUT_PATH="$REPO_DIR/$OUTPUT_NAME"
    INPUT_PATH="$REPO_DIR/$ENV_EXAMPLE"

    if [ ! -f "$OUTPUT_PATH" ] && [ -f "$INPUT_PATH" ]; then
      echo "[env] Re-resolving $NAME/$OUTPUT_NAME (missing)..."
      if grep -q "arn:aws:secretsmanager:" "$INPUT_PATH" 2>/dev/null && [ -f "$RESOLVE_SCRIPT" ]; then
        bash "$RESOLVE_SCRIPT" "$INPUT_PATH" "$OUTPUT_PATH"
      else
        cp "$INPUT_PATH" "$OUTPUT_PATH"
      fi
    fi
  done
done

# Top-level repoEnvFiles (ops pattern)
if jq -e '.repoEnvFiles' workspace.json > /dev/null 2>&1 && [ -f "$RESOLVE_SCRIPT" ]; then
  for NAME in $(jq -r '.repoEnvFiles // {} | keys[]' workspace.json 2>/dev/null); do
    REPO_DIR="$WORKSPACE_DIR/$NAME"
    if [ ! -d "$REPO_DIR" ]; then continue; fi
    for ENV_EXAMPLE in $(jq -r ".repoEnvFiles[\"$NAME\"] | keys[]" workspace.json 2>/dev/null); do
      OUTPUT_NAME=$(jq -r ".repoEnvFiles[\"$NAME\"][\"$ENV_EXAMPLE\"]" workspace.json)
      OUTPUT_PATH="$REPO_DIR/$OUTPUT_NAME"
      INPUT_PATH="$REPO_DIR/$ENV_EXAMPLE"
      if [ ! -f "$OUTPUT_PATH" ] && [ -f "$INPUT_PATH" ]; then
        echo "[env] Re-resolving $NAME/$OUTPUT_NAME (missing)..."
        if grep -q "arn:aws:secretsmanager:" "$INPUT_PATH" 2>/dev/null; then
          bash "$RESOLVE_SCRIPT" "$INPUT_PATH" "$OUTPUT_PATH"
        else
          cp "$INPUT_PATH" "$OUTPUT_PATH"
        fi
      fi
    done
  done
fi

# Top-level envFiles with inline content (ops pattern)
if [ -f "workspace.json" ] && jq -e '.envFiles' workspace.json > /dev/null 2>&1; then
  for NAME in $(jq -r '.envFiles // {} | keys[]' workspace.json 2>/dev/null); do
    if [ ! -d "$WORKSPACE_DIR/$NAME" ]; then continue; fi
    for ENV_FILE in $(jq -r ".envFiles[\"$NAME\"] | keys[]" workspace.json 2>/dev/null); do
      if [ ! -f "$WORKSPACE_DIR/$NAME/$ENV_FILE" ]; then
        CONTENT=$(jq -r ".envFiles[\"$NAME\"][\"$ENV_FILE\"]" workspace.json)
        echo -e "$CONTENT" > "$WORKSPACE_DIR/$NAME/$ENV_FILE"
        echo "[env] Regenerated $NAME/$ENV_FILE"
      fi
    done
  done
fi

# ── Re-write vibe-ui .env if missing ──
if [ ! -f "$WORKSPACE_DIR/vibe-ui/.env" ] && [ -n "$ANTHROPIC_API_KEY" ]; then
  echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" > "$WORKSPACE_DIR/vibe-ui/.env"
  echo "[env] Re-created vibe-ui/.env"
fi

# ── Patch frontend API URL for Codespace forwarded port ──
if [ "$CODESPACES" = "true" ]; then
  CS_NAME="${CODESPACE_NAME:-}"
  [ -z "$CS_NAME" ] && [ -f "$HOME/.codespace-name" ] && CS_NAME=$(cat "$HOME/.codespace-name")

  if [ -n "$CS_NAME" ]; then
    PATCH_REPO=$(jq -r '.frontendApiPatching.repo // empty' workspace.json)
    PATCH_FILE=$(jq -r '.frontendApiPatching.file // empty' workspace.json)
    PATCH_VAR=$(jq -r '.frontendApiPatching.envVar // empty' workspace.json)
    PATCH_PORT=$(jq -r '.frontendApiPatching.apiPort // empty' workspace.json)
    PATCH_SUFFIX=$(jq -r '.frontendApiPatching.suffix // "/"' workspace.json)

    if [ -n "$PATCH_REPO" ] && [ -n "$PATCH_VAR" ] && [ -n "$PATCH_PORT" ]; then
      API_URL="https://${CS_NAME}-${PATCH_PORT}.app.github.dev${PATCH_SUFFIX}"
      TARGET_FILE="$WORKSPACE_DIR/$PATCH_REPO/$PATCH_FILE"
      if [ -f "$TARGET_FILE" ]; then
        sed -i "s|${PATCH_VAR}=.*|${PATCH_VAR}=${API_URL}|" "$TARGET_FILE"
        echo "[env] Patched ${PATCH_VAR} → ${API_URL}"
      fi
    fi
  fi
fi

# ── Clear old logs ──
for f in /tmp/*.log; do > "$f" 2>/dev/null; done

# ── Kill leftover processes on all ports ──
for PORT in $ALL_PORTS; do
  kill $(lsof -ti:$PORT -sTCP:LISTEN) 2>/dev/null || true
done
sleep 1

# ── Enable corepack for yarn-based repos ──
sudo corepack enable 2>/dev/null || true

# ── Clear frontend webpack cache (env vars are baked at compile time) ──
for i in $(seq 0 $((REPO_COUNT - 1))); do
  TYPE=$(jq -r ".repos[$i].type // empty" workspace.json)
  NAME=$(jq -r ".repos[$i].name" workspace.json)
  if [ "$TYPE" = "frontend" ] && [ -d "$WORKSPACE_DIR/$NAME/node_modules/.cache" ]; then
    rm -rf "$WORKSPACE_DIR/$NAME/node_modules/.cache"
    echo "[cache] Cleared webpack cache for $NAME"
  fi
done

# ── Start vibe-ui (always port 4000, always background) ──
if [ -d "$WORKSPACE_DIR/vibe-ui/node_modules" ]; then
  VIBE_DATA="$WORKSPACE_DIR/.vibe-data"
  mkdir -p "$VIBE_DATA"
  (cd "$WORKSPACE_DIR/vibe-ui" && CLAUDECK_HOME="$VIBE_DATA" WORKSPACE_DIR="$WORKSPACE_DIR" ANTHROPIC_API_KEY=$(cat .env 2>/dev/null | grep ANTHROPIC | cut -d= -f2) node server-washmen.js >> /tmp/vibe.log 2>&1) &
  echo "[start] ▶ vibe-ui → :4000"
fi

# ── Set port visibility (background, non-blocking) ──
if [ "$CODESPACES" = "true" ] && command -v gh &>/dev/null; then
  PORT_ARGS=""
  for PORT in $(jq -r '.portsAttributes | to_entries[] | select(.value.visibility == "public") | .key' .devcontainer/devcontainer.json 2>/dev/null); do
    PORT_ARGS="$PORT_ARGS $PORT:public"
  done
  if [ -n "$PORT_ARGS" ]; then
    TOKEN="${GITHUB_TOKEN:-}"
    [ -z "$TOKEN" ] && [ -f "$HOME/.gh-token" ] && TOKEN=$(cat "$HOME/.gh-token")
    CS_NAME="${CODESPACE_NAME:-}"
    [ -z "$CS_NAME" ] && [ -f "$HOME/.codespace-name" ] && CS_NAME=$(cat "$HOME/.codespace-name")

    if [ -n "$TOKEN" ] && [ -n "$CS_NAME" ]; then
      (sleep 15 && GH_TOKEN="$TOKEN" gh codespace ports visibility $PORT_ARGS -c "$CS_NAME" 2>/dev/null && echo "[ports] ✓ Ports set to public" || echo "[ports] ✗ Could not set ports public") &
    fi
  fi
fi

# ══════════════════════════════════════════════════════════════
# SERVICE STARTUP — mode determined by workspace.json "startup"
# ══════════════════════════════════════════════════════════════

if [ "$STARTUP_MODE" = "foreground" ]; then
  # ── Monorepo mode: single repo runs in foreground via exec ──
  echo "[start] Launching in foreground mode..."
  for i in $(seq 0 $((REPO_COUNT - 1))); do
    NAME=$(jq -r ".repos[$i].name" workspace.json)
    DEV=$(jq -r ".repos[$i].dev // empty" workspace.json)

    if [ -n "$DEV" ] && [ -d "$WORKSPACE_DIR/$NAME/node_modules" ]; then
      echo "[start] ▶ $NAME (foreground): $DEV"
      cd "$WORKSPACE_DIR/$NAME"
      exec $DEV 2>&1 | tee /tmp/${NAME}.log
    fi
  done
else
  # ── Multi-repo mode: each repo runs as background process ──
  echo "[start] Launching services..."
  for i in $(seq 0 $((REPO_COUNT - 1))); do
    NAME=$(jq -r ".repos[$i].name" workspace.json)
    PORT=$(jq -r ".repos[$i].port // empty" workspace.json)
    DEV=$(jq -r ".repos[$i].dev // empty" workspace.json)
    NODE_OPTS=$(jq -r ".repos[$i].nodeOptions // empty" workspace.json)

    if [ -z "$DEV" ] || [ ! -d "$WORKSPACE_DIR/$NAME/node_modules" ]; then
      echo "[start] ⊘ $NAME — skipped (no dev command or missing deps)"
      continue
    fi

    ENV_PREFIX=""
    [ -n "$NODE_OPTS" ] && ENV_PREFIX="export NODE_OPTIONS=$NODE_OPTS && "

    LOG="/tmp/${NAME}.log"
    (cd "$WORKSPACE_DIR/$NAME" && eval "${ENV_PREFIX}${DEV}" >> "$LOG" 2>&1) &
    echo "[start] ▶ $NAME → :$PORT"
  done

  # ── Health check: wait for all ports ──
  echo ""
  echo "[health] Waiting for services to be ready..."
  TIMEOUT=90
  ELAPSED=0
  while [ $ELAPSED -lt $TIMEOUT ]; do
    ALL_UP=true
    for PORT in $ALL_PORTS; do
      if ! lsof -ti:$PORT -sTCP:LISTEN > /dev/null 2>&1; then
        ALL_UP=false
        break
      fi
    done
    if [ "$ALL_UP" = true ]; then
      break
    fi
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    echo "[health] ... ${ELAPSED}s elapsed"
  done

  echo ""
  for PORT in $ALL_PORTS; do
    if lsof -ti:$PORT -sTCP:LISTEN > /dev/null 2>&1; then
      echo "[health] :$PORT ✓ up"
    else
      echo "[health] :$PORT ✗ NOT LISTENING"
    fi
  done

  echo ""
  echo "╔══════════════════════════════════════════╗"
  echo "║       READY — $(date '+%H:%M:%S')                       ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""

  # Keep alive so background processes aren't reaped
  wait
fi
