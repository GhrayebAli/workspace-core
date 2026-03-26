#!/bin/bash
# Generic service startup — reads everything from workspace.json
# Self-healing: installs missing deps, starts services, verifies health, sets ports public.
# Works on: create, start, stop/start, restart, rebuild — zero intervention.

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

# ── Collect all ports for health check later ──
ALL_PORTS="4000"
for i in $(seq 0 $((REPO_COUNT - 1))); do
  PORT=$(jq -r ".repos[$i].port // empty" workspace.json)
  [ -n "$PORT" ] && ALL_PORTS="$ALL_PORTS $PORT"
done

# ── Ensure deps exist (self-healing) ──
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

# ── Regenerate .env files if missing (setup.sh creates them, but git checkout can wipe them) ──
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
  # Patch frontend API URL for Codespace forwarded port
  if [ "$CODESPACES" = "true" ]; then
    CS_NAME="${CODESPACE_NAME:-}"
    [ -z "$CS_NAME" ] && [ -f "$HOME/.codespace-name" ] && CS_NAME=$(cat "$HOME/.codespace-name")
    if [ -n "$CS_NAME" ]; then
      for i in $(seq 0 $((REPO_COUNT - 1))); do
        TYPE=$(jq -r ".repos[$i].type // empty" workspace.json)
        NAME=$(jq -r ".repos[$i].name" workspace.json)
        if [ "$TYPE" = "frontend" ]; then
          # Find the API gateway port
          for j in $(seq 0 $((REPO_COUNT - 1))); do
            JTYPE=$(jq -r ".repos[$j].type // empty" workspace.json)
            JPORT=$(jq -r ".repos[$j].port // empty" workspace.json)
            if [ "$JTYPE" = "backend" ] && [ -n "$JPORT" ]; then
              API_URL="https://${CS_NAME}-${JPORT}.app.github.dev"
              DEV_ENV="$WORKSPACE_DIR/$NAME/.env.development"
              if [ -f "$DEV_ENV" ] && grep -q "REACT_APP_INTERNAL_API_OPS" "$DEV_ENV"; then
                sed -i "s|REACT_APP_INTERNAL_API_OPS=.*|REACT_APP_INTERNAL_API_OPS=${API_URL}/|" "$DEV_ENV"
                echo "[env] Patched $NAME API URL → $API_URL"
              fi
              break
            fi
          done
        fi
      done
    fi
  fi
fi

# ── Patch backend CORS for Codespace cross-origin requests ──
# Sails.js reads CORS from config/env/development.js, not .env
# Browser sends baggage/sentry-trace (Sentry), x-vibe-token (vibe-ui) headers
for i in $(seq 0 $((REPO_COUNT - 1))); do
  TYPE=$(jq -r ".repos[$i].type // empty" workspace.json)
  NAME=$(jq -r ".repos[$i].name" workspace.json)
  CORS_FILE="$WORKSPACE_DIR/$NAME/config/env/development.js"
  if [ "$TYPE" = "backend" ] && [ -f "$CORS_FILE" ]; then
    if ! grep -q "baggage" "$CORS_FILE" 2>/dev/null; then
      sed -i "s|cors: {|cors: {\n      allRoutes: true,\n      allowOrigins: '*',\n      allowRequestHeaders: 'content-type, Authorization, manager-password, user-timestamp, auth, refresh, x-vibe-token, baggage, sentry-trace',|" "$CORS_FILE"
      echo "[cors] Patched $NAME CORS config"
    fi
  fi
done

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

# ── Start services from workspace.json ──
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

# ── Start vibe-ui (always port 4000) ──
if [ -d "$WORKSPACE_DIR/vibe-ui/node_modules" ]; then
  # Store vibe-ui data under /workspaces/ so it survives codespace rebuilds
  VIBE_DATA="$WORKSPACE_DIR/.vibe-data"
  mkdir -p "$VIBE_DATA"
  (cd "$WORKSPACE_DIR/vibe-ui" && CLAUDECK_HOME="$VIBE_DATA" WORKSPACE_DIR="$WORKSPACE_DIR" ANTHROPIC_API_KEY=$(cat .env 2>/dev/null | grep ANTHROPIC | cut -d= -f2) node server-washmen.js >> /tmp/vibe.log 2>&1) &
  echo "[start] ▶ vibe-ui → :4000"
fi

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

# ── Set port visibility from devcontainer.json (only public ports, keep DB services private) ──
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

    echo "[ports] Setting public:$PORT_ARGS"
    if [ -n "$TOKEN" ] && [ -n "$CS_NAME" ]; then
      GH_TOKEN="$TOKEN" gh codespace ports visibility $PORT_ARGS -c "$CS_NAME" 2>/dev/null && echo "[ports] ✓ Ports set to public" || echo "[ports] ✗ Could not set ports public"
    else
      echo "[ports] ✗ No token ($([ -f $HOME/.gh-token ] && echo 'file exists' || echo 'no file')) or codespace name ($([ -f $HOME/.codespace-name ] && echo 'file exists' || echo 'no file'))"
    fi
  fi
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       READY — $(date '+%H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Keep alive so background processes aren't reaped
wait
