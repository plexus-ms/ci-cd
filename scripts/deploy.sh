#!/usr/bin/env bash
#
# Plexus deploy verb — § 8.4 PLX. A stateless procedure, not a system:
#
#   ssh → docker compose pull → compose run --rm migrate (if declared) → docker compose up -d
#       → poll /healthz → on failure: re-up the previous image, exit non-zero
#
# Migrations are an artifact capability, not a host toolchain: an app that has
# them declares a one-shot `migrate` service in compose.yaml (same image, migrate
# command, `profiles: ["migrate"]` so plain `up` never starts it). The host
# needs nothing but docker.
#
# The `web` service name targeted below is the app-contract convention,
# shipped by preset-app-nextjs's compose.yaml.jinja.
#
# State lives in git (compose.yaml, placed on the host by the
# tenant's Ansible) and in the registry (the image). "Which version is live" is the
# running container's image, queried from `docker` (reality) — never a file we own.
# No persistent state, no daemon, no UI, no reconciliation loop.
#
# Degradation test — hand-runnable with no extra machinery:
#   ./deploy.sh deploy@1.2.3.4 plexus-website ghcr.io/org/plexus-website:<sha>
#
set -euo pipefail

HOST="${1:?usage: deploy.sh <ssh-host> <app> <image-ref>}"
APP="${2:?usage: deploy.sh <ssh-host> <app> <image-ref>}"
IMAGE="${3:?usage: deploy.sh <ssh-host> <app> <image-ref>}"

# Overridable knobs (sane defaults for the stateless-app profile).
APP_DIR="${PLEXUS_APP_DIR:-/opt/stacks/$APP}"
HEALTH_URL="${PLEXUS_HEALTH_URL:-http://127.0.0.1:3000/healthz}"
RETRIES="${PLEXUS_HEALTH_RETRIES:-30}"

echo "→ deploying $IMAGE"
echo "  host:   $HOST"
echo "  dir:    $APP_DIR"
echo "  health: $HEALTH_URL"

# Everything below runs on the host. Args are passed positionally (no fragile
# remote-env forwarding); the heredoc is quoted so it is not expanded locally.
ssh -o StrictHostKeyChecking=accept-new "$HOST" bash -seuo pipefail -- \
  "$APP_DIR" "$IMAGE" "$HEALTH_URL" "$RETRIES" <<'REMOTE'
APP_DIR="$1"; IMAGE="$2"; HEALTH_URL="$3"; RETRIES="$4"
cd "$APP_DIR"

# Reality is the source of truth: read the currently-live image for rollback.
PREV_IMAGE=""
CID="$(docker compose ps -q web 2>/dev/null || true)"
[ -n "$CID" ] && PREV_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$CID" 2>/dev/null || true)"
echo "  previous: ${PREV_IMAGE:-<none>}"

up() {  # $1 = image ref
  echo "IMAGE=$1" > .env   # reproducibility cache for a manual `docker compose up`
  IMAGE="$1" docker compose pull web
  IMAGE="$1" docker compose up -d web
}

healthy() {
  for _ in $(seq 1 "$RETRIES"); do
    curl -fsS -o /dev/null "$HEALTH_URL" && return 0
    sleep 2
  done
  return 1
}

# Pull → migrate (idempotent; runs only if compose.yaml declares it) → up.
# A migrate failure aborts before `up`, so the previous release keeps serving.
echo "IMAGE=$IMAGE" > .env
IMAGE="$IMAGE" docker compose pull web
# `compose run` targets the service regardless of its profile; the --profile
# flag is only needed for the existence check, since `config --services`
# hides profiled services by default.
if IMAGE="$IMAGE" docker compose --profile migrate config --services 2>/dev/null | grep -qx migrate; then
  IMAGE="$IMAGE" docker compose run --rm migrate
fi
IMAGE="$IMAGE" docker compose up -d web

if healthy; then
  echo "✓ $IMAGE is live and healthy"
  exit 0
fi

echo "✗ healthcheck failed after $((RETRIES * 2))s"
if [ -n "$PREV_IMAGE" ] && [ "$PREV_IMAGE" != "$IMAGE" ]; then
  echo "↩ rolling back to $PREV_IMAGE"
  up "$PREV_IMAGE"
  if healthy; then echo "✓ rolled back to $PREV_IMAGE"; else echo "✗ rollback also unhealthy — manual intervention needed"; fi
fi
exit 1
REMOTE
