#!/bin/bash
# Generic service startup — reads everything from workspace.json
# Self-healing: installs missing deps, starts services, verifies health, sets ports public.
# Works on: create, start, stop/start, restart, rebuild — zero intervention.

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspaces/$(basename "$(pwd)")}"
cd "$WORKSPACE_DIR"

echo "=== Starting services ($(date '+%H:%M:%S')) ==="

if [ ! -f "workspace.json" ]; then
  echo "ERROR: workspace.json not found"
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
for i in $(seq 0 $((REPO_COUNT - 1))); do
  NAME=$(jq -r ".repos[$i].name" workspace.json)
  PKG_MGR=$(jq -r ".repos[$i].packageManager // \"npm\"" workspace.json)
  NODE_OPTS=$(jq -r ".repos[$i].nodeOptions // empty" workspace.json)

  if [ -d "$WORKSPACE_DIR/$NAME" ] && [ ! -d "$WORKSPACE_DIR/$NAME/node_modules" ]; then
    echo "$NAME deps missing — installing..."
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
  echo "vibe-ui deps missing — installing..."
  (cd "$WORKSPACE_DIR/vibe-ui" && npm install)
fi

# ── Restore active branch ──
if [ -f "$WORKSPACE_DIR/.active-branch" ]; then
  BRANCH=$(cat "$WORKSPACE_DIR/.active-branch")
  echo "Restoring branch: $BRANCH"
  for i in $(seq 0 $((REPO_COUNT - 1))); do
    NAME=$(jq -r ".repos[$i].name" workspace.json)
    git -C "$WORKSPACE_DIR/$NAME" checkout "$BRANCH" 2>/dev/null || true
  done
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

# ── Start services from workspace.json ──
for i in $(seq 0 $((REPO_COUNT - 1))); do
  NAME=$(jq -r ".repos[$i].name" workspace.json)
  PORT=$(jq -r ".repos[$i].port // empty" workspace.json)
  DEV=$(jq -r ".repos[$i].dev // empty" workspace.json)
  NODE_OPTS=$(jq -r ".repos[$i].nodeOptions // empty" workspace.json)

  if [ -z "$DEV" ] || [ ! -d "$WORKSPACE_DIR/$NAME/node_modules" ]; then
    echo "SKIP: $NAME (no dev command or missing deps)"
    continue
  fi

  ENV_PREFIX=""
  [ -n "$NODE_OPTS" ] && ENV_PREFIX="export NODE_OPTIONS=$NODE_OPTS && "

  LOG="/tmp/${NAME}.log"
  (cd "$WORKSPACE_DIR/$NAME" && eval "${ENV_PREFIX}${DEV}" >> "$LOG" 2>&1) &
  echo "  $NAME → :$PORT"
done

# ── Start vibe-ui (always port 4000) ──
if [ -d "$WORKSPACE_DIR/vibe-ui/node_modules" ]; then
  (cd "$WORKSPACE_DIR/vibe-ui" && ANTHROPIC_API_KEY=$(cat .env 2>/dev/null | grep ANTHROPIC | cut -d= -f2) node server-washmen.js >> /tmp/vibe.log 2>&1) &
  echo "  vibe-ui → :4000"
fi

# ── Health check: wait for all ports ──
echo "Waiting for services..."
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
done

# ── Report health ──
echo ""
echo "=== Service Status ==="
for PORT in $ALL_PORTS; do
  if lsof -ti:$PORT -sTCP:LISTEN > /dev/null 2>&1; then
    echo "  :$PORT ✓"
  else
    echo "  :$PORT ✗ (not listening)"
  fi
done

# ── Set port visibility from devcontainer.json (only public ports, keep DB services private) ──
if [ "$CODESPACES" = "true" ] && command -v gh &>/dev/null; then
  PORT_ARGS=""
  for PORT in $(jq -r '.portsAttributes | to_entries[] | select(.value.visibility == "public") | .key' .devcontainer/devcontainer.json 2>/dev/null); do
    PORT_ARGS="$PORT_ARGS $PORT:public"
  done
  # CODESPACE_NAME is set during devcontainer lifecycle but may be empty in SSH
  if [ -n "$CODESPACE_NAME" ]; then
    gh codespace ports visibility $PORT_ARGS -c "$CODESPACE_NAME" 2>/dev/null && echo "Ports set to public" || echo "WARN: Could not set ports public (run: gh codespace ports visibility $PORT_ARGS)"
  else
    # Try without -c flag (may work with GITHUB_TOKEN)
    gh codespace ports visibility $PORT_ARGS 2>/dev/null && echo "Ports set to public" || echo "WARN: Set ports public manually: gh codespace ports visibility $PORT_ARGS"
  fi
fi

echo "=== Ready ($(date '+%H:%M:%S')) ==="

# Keep alive so background processes aren't reaped
wait
