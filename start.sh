#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REPO_DIR="$SCRIPT_DIR/label-studio-ml-backend"
REPO_URL="https://github.com/HumanSignal/label-studio-ml-backend"
PATCH_FILE="$SCRIPT_DIR/patches/grounding-dino-local-fixes.patch"
PINNED_COMMIT="$(cat "$SCRIPT_DIR/patches/grounding-dino-local-fixes.commit")"

if [ ! -d "$REPO_DIR" ]; then
  echo "==> Cloning label-studio-ml-backend..."
  git clone "$REPO_URL" "$REPO_DIR"
fi

echo "==> Checking out pinned commit $PINNED_COMMIT..."
git -C "$REPO_DIR" checkout "$PINNED_COMMIT"

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

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "ERROR: .env not found. Create one with LABEL_STUDIO_API_KEY and LABEL_STUDIO_LEGACY_TOKEN (see README.md 'First-time setup')." >&2
  exit 1
fi

echo "==> Building and starting services..."
docker compose up -d --build

echo "==> Waiting for grounding-dino-ml-backend to become healthy..."
ready=false
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
  echo "WARNING: grounding-dino-ml-backend did not report healthy within 5 minutes. Check: docker compose logs grounding-dino-ml-backend" >&2
fi

echo ""
echo "Label Studio:           http://localhost:8080"
echo "Grounding DINO backend: http://localhost:9090/health"
