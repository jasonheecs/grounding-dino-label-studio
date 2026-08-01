#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REPO_DIR="$SCRIPT_DIR/label-studio-ml-backend"
REPO_URL="https://github.com/HumanSignal/label-studio-ml-backend"
PATCH_FILE="$SCRIPT_DIR/patches/grounding-dino-local-fixes.patch"
PINNED_COMMIT="$(cat "$SCRIPT_DIR/patches/grounding-dino-local-fixes.commit")"

if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
  COMPOSE=(podman compose)
else
  COMPOSE=(docker compose)
fi

clone_ml_backend_repo() {
  if [ ! -d "$REPO_DIR" ]; then
    echo "==> Cloning label-studio-ml-backend..."
    git clone "$REPO_URL" "$REPO_DIR"
  fi
}

checkout_pinned_commit() {
  echo "==> Checking out pinned commit $PINNED_COMMIT..."
  git -C "$REPO_DIR" checkout "$PINNED_COMMIT"
}

apply_local_patches() {
  if git -C "$REPO_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    echo "==> Applying local Grounding DINO fixes..."
    git -C "$REPO_DIR" apply "$PATCH_FILE"
  elif git -C "$REPO_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    echo "==> Local fixes already applied, skipping."
  else
    echo "ERROR: patch doesn't apply cleanly against $PINNED_COMMIT and isn't already applied." >&2
    echo "Check patches/grounding-dino-local-fixes.patch manually." >&2
    exit 1
  fi
}

generate_env_if_missing() {
  if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "==> No .env found, generating fresh Label Studio credentials..."
    local gen_username="admin@myhost.local"
    local gen_password
    gen_password="$(head -c 12 <(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null))"
    local gen_token
    gen_token="$(openssl rand -hex 20)"
    cat >"$SCRIPT_DIR/.env" <<EOF
LABEL_STUDIO_USERNAME=$gen_username
LABEL_STUDIO_PASSWORD=$gen_password
LABEL_STUDIO_LEGACY_TOKEN=$gen_token
EOF
    echo "==> Generated .env with a fresh admin account:"
    echo "      username: $gen_username"
    echo "      password: $gen_password"
    echo "    (also saved in .env — use these to log into the Label Studio UI)"
  fi

  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
}

start_services() {
  echo "==> Building and starting services..."
  "${COMPOSE[@]}" up -d --build
}

verify_label_studio_auth() {
  echo "==> Verifying the generated Label Studio token actually works..."
  local auth_ok=false
  for _ in $(seq 1 60); do
    if curl -sf -H "Authorization: Token $LABEL_STUDIO_LEGACY_TOKEN" http://localhost:8080/api/current-user/whoami >/dev/null 2>&1; then
      auth_ok=true
      break
    fi
    sleep 5
  done

  if [ "$auth_ok" = true ]; then
    echo "==> Label Studio auth check passed."
  else
    echo "ERROR: could not authenticate to Label Studio with the generated legacy token." >&2
    echo "Fallback: log into http://localhost:8080, enable legacy tokens for your org" >&2
    echo "(Organization -> API Tokens Settings, or POST /api/jwt/settings), grab a token," >&2
    echo "and set LABEL_STUDIO_LEGACY_TOKEN in .env manually. See README.md 'Auth'." >&2
    exit 1
  fi
}

wait_for_grounding_dino_healthy() {
  echo "==> Waiting for grounding-dino-ml-backend to become healthy..."
  local ready=false
  for _ in $(seq 1 60); do
    if curl -sf http://localhost:9090/health >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 5
  done

  if [ "$ready" = true ]; then
    echo "==> grounding-dino-ml-backend is up."
  else
    echo "WARNING: grounding-dino-ml-backend did not report healthy within 5 minutes. Check: ${COMPOSE[*]} logs grounding-dino-ml-backend" >&2
  fi
}

print_summary() {
  echo ""
  echo "Label Studio:           http://localhost:8080"
  echo "Grounding DINO backend: http://localhost:9090/health"
}

main() {
  clone_ml_backend_repo
  checkout_pinned_commit
  apply_local_patches
  generate_env_if_missing
  start_services
  verify_label_studio_auth
  wait_for_grounding_dino_healthy
  print_summary
}

main "$@"
