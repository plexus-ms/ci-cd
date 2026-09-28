#!/usr/bin/env bash
#
# Plexus deploy verb — § 8.4 PLX. A stateless procedure, not a system:
#
#   render compose.yaml from the invoking checkout, pinning the image ref (§ 5.2, § 5.3 PLX)
#   → ssh → docker compose pull → compose run --rm migrate (if declared), both against the staged file
#         → swap the file into place → docker compose up -d → poll the readiness path
#         → on failure: restore the previous file, docker compose up -d (no pull), exit non-zero
#
# Run from a checkout of the app's SOURCE repo (§ 5.2 PLX): an app repo's CI,
# or the platform repo for third-party software the tenant merely operates.
# The app's run shape — apps/<app>/docker/compose.yaml (or apps/<app>/compose.yaml)
# — is read from there, rendered with the concrete image ref in place of
# ${PLEXUS_DEPLOYMENT_IMAGE}, staged on the host, and swapped into place only
# once pull and migrate have succeeded, so the compose file on the host always
# names the image it serves — and a failed deploy leaves the host exactly as
# it was. Three files in the app dir, one writer each (§ 7.2 PLX): the
# configure playbook owns .env and .env.secret, this verb owns compose.yaml.
# Compose reads .env implicitly, so every invocation here, in the playbook's
# rotation handler, and by a human is a bare `docker compose …`.
#
# Migrations are an artifact capability, not a host toolchain: an app that has
# them declares a one-shot `migrate` service in compose.yaml (same image, migrate
# command, `profiles: ["migrate"]` so plain `up` never starts it). The host
# needs nothing but docker.
#
# The `web` service name targeted below is the app-contract convention,
# shipped by preset-app-nextjs's compose.yaml.jinja; a third-party compose file
# names its app service `web` as well.
#
# "Which version is live" is the running container's image, queried from
# `docker` (reality) — never a file we own. No persistent state, no daemon,
# no UI, no reconciliation loop.
#
# Degradation test — hand-runnable with no extra machinery, from the source repo:
#   git clone <source repo> && cd <it>
#   /path/to/deploy.sh deploy@1.2.3.4 plexus website ghcr.io/org/website:<sha>
#
# A third-party app pins its image inside compose.yaml; pass '' as the image
# ref and the file is placed as is.
#
set -euo pipefail

USAGE="usage: deploy.sh <ssh-host> <tenant> <app> <image-ref|''>"
HOST="${1:?$USAGE}"
TENANT="${2:?$USAGE}"
APP="${3:?$USAGE}"
IMAGE="${4?$USAGE}"

# Overridable knobs (sane defaults for the stateless-app profile). The app dir
# mirrors the configure playbook's layout: <deploy root>/<tenant>/<app>. An
# empty HEALTH_URL is resolved on the host from .env's PLEXUS_LOOPBACK_PORT
# and the app's `plexus.healthz` label (§ 5.5 PLX), defaulting to /healthz.
APP_DIR="${PLEXUS_APP_DIR:-/opt/stacks/$TENANT/$APP}"
APP_SRC="${PLEXUS_APP_SRC:-apps/$APP}"
HEALTH_URL="${PLEXUS_HEALTH_URL:-}"
RETRIES="${PLEXUS_HEALTH_RETRIES:-30}"

# The run shape, from the invoking checkout (§ 5.2 PLX).
COMPOSE=""
for candidate in "$APP_SRC/docker/compose.yaml" "$APP_SRC/compose.yaml"; do
  [ -f "$candidate" ] && { COMPOSE="$candidate"; break; }
done
[ -n "$COMPOSE" ] || { echo "✗ no compose.yaml under $APP_SRC — run from the app's source repo" >&2; exit 2; }

echo "→ deploying ${IMAGE:-<image pinned in compose.yaml>}"
echo "  host:    $HOST"
echo "  dir:     $APP_DIR"
echo "  compose: $COMPOSE"
echo "  health:  ${HEALTH_URL:-<resolved on host>}"

# Render: pin the image ref in place of the ${PLEXUS_DEPLOYMENT_IMAGE} placeholder
# (§ 5.3 PLX), with or without a `:?message` suffix. One literal substitution,
# nothing else in the file is touched. A first-party file without the
# placeholder would silently ignore the ref, and a third-party file with one
# would ship an empty image — both are errors here, never on the host.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PLACEHOLDER='\$\{PLEXUS_DEPLOYMENT_IMAGE(:[^}]*)?\}'
if [ -n "$IMAGE" ]; then
  grep -Eq "$PLACEHOLDER" "$COMPOSE" \
    || { echo "✗ $COMPOSE does not reference \${PLEXUS_DEPLOYMENT_IMAGE} — an image ref was given but nothing would use it (§ 5.3 PLX)" >&2; exit 2; }
  sed -E "s|$PLACEHOLDER|$IMAGE|g" "$COMPOSE" > "$STAGE/compose.yaml"
else
  ! grep -Eq "$PLACEHOLDER" "$COMPOSE" \
    || { echo "✗ $COMPOSE references \${PLEXUS_DEPLOYMENT_IMAGE} but no image ref was given" >&2; exit 2; }
  cp "$COMPOSE" "$STAGE/compose.yaml"
fi

QDIR="$(printf '%q' "$APP_DIR")"

# Stage the rendered file, as one tar stream over ssh, into a verb-owned
# staging dir inside the app dir. Only the file is named (never `.`), so the
# app dir's own mode, set by the playbook, is left alone. Nothing the host
# currently runs from is touched until the checks below have passed.
tar -C "$STAGE" -cf - compose.yaml \
  | ssh -o StrictHostKeyChecking=accept-new "$HOST" \
      "rm -rf $QDIR/.incoming && mkdir -p $QDIR/.incoming && tar -xf - -C $QDIR/.incoming"

# Everything below runs on the host. Args are passed positionally (no fragile
# remote-env forwarding); the heredoc is quoted so it is not expanded locally.
# ssh flattens its argv into one space-joined string, so each arg is %q-quoted
# to survive the remote shell's re-parsing — an empty arg would vanish otherwise.
ssh -o StrictHostKeyChecking=accept-new "$HOST" bash -seuo pipefail -- \
  "$QDIR" "$(printf '%q' "$HEALTH_URL")" "$(printf '%q' "$RETRIES")" <<'REMOTE'
APP_DIR="$1"; HEALTH_URL="$2"; RETRIES="$3"
cd "$APP_DIR"
IN=.incoming                 # staged run shape + rollback copy; gone on exit
trap 'rm -rf "$IN"' EXIT

# No env-file wiring: compose reads the playbook's .env from the project dir
# implicitly, and the image is pinned in the file. .env is dotenv, not shell:
# the one value this verb needs is read by name — sourcing it would execute
# inventory values as code.
PORT="$(sed -n 's/^PLEXUS_LOOPBACK_PORT=//p' .env 2>/dev/null | tail -1 || true)"
dc()  { docker compose "$@"; }
# The staged compose file, read in place: --project-directory keeps .env and
# relative paths (env_file) resolving against the app dir, so pull and migrate
# run against the new run shape while the host keeps serving from the old one.
dci() { dc --project-directory . -f "$IN/compose.yaml" "$@"; }

# Reality is the source of truth: read the currently-live image, from the run
# shape the host is serving right now.
PREV_IMAGE=""
CID="$(dc ps -q web 2>/dev/null | head -1 || true)"
[ -n "$CID" ] && PREV_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$CID" 2>/dev/null || true)"
echo "  previous: ${PREV_IMAGE:-<none>}"

# Readiness path: /healthz by contract (§ 5.5 PLX); a third-party image that
# cannot serve it declares its own via the `plexus.healthz` label, read from
# the running container — reality, not a parse of the compose file.
resolve_health_url() {
  [ -n "$HEALTH_URL" ] && return 0
  local cid path
  cid="$(dc ps -q web 2>/dev/null | head -1 || true)"
  path=""
  [ -n "$cid" ] && path="$(docker inspect --format '{{ index .Config.Labels "plexus.healthz" }}' "$cid" 2>/dev/null || true)"
  HEALTH_URL="http://127.0.0.1:${PORT:-3000}${path:-/healthz}"
  echo "  health:   $HEALTH_URL"
}

# Deadline-based poll (§ 8.4 PLX): each attempt is bounded, so a container
# that accepts connections but never answers cannot hang the deploy.
healthy() {
  resolve_health_url
  for _ in $(seq 1 "$RETRIES"); do
    curl -fsS --max-time 5 -o /dev/null "$HEALTH_URL" && return 0
    sleep 2
  done
  return 1
}

# Pull → migrate (idempotent; runs only if compose.yaml declares it), both
# against the STAGED run shape: a failure here leaves the host exactly as it
# was — old compose file, old containers — and the previous release keeps
# serving.
dci pull web
# `compose run` targets the service regardless of its profile; the --profile
# flag is only needed for the existence check, since `config --services`
# hides profiled services by default.
if dci --profile migrate config --services 2>/dev/null | grep -qx migrate; then
  # stdin MUST be /dev/null: this whole script arrives on ssh's stdin, and
  # `compose run` is interactive by default — it would swallow the remaining
  # script text, ending the deploy after migrate with exit 0 (silent no-op:
  # `up -d web` and the health poll never run).
  dci run --rm migrate </dev/null
fi

# Swap the run shape into place — the previous one is kept for rollback until
# this run ends.
HAD_PREV=0
if [ -f compose.yaml ]; then cp -p compose.yaml "$IN/compose.yaml.prev"; HAD_PREV=1; fi
mv "$IN/compose.yaml" compose.yaml

# No pull here: the new image was pulled above, the previous one is in the
# host's cache — a rollback must never depend on the registry answering.
dc up -d web
t0=$SECONDS
if healthy; then
  echo "✓ $(dc ps -q web | head -1 | xargs -r docker inspect --format '{{.Config.Image}}') is live and healthy"
  exit 0
fi
echo "✗ healthcheck failed after $((SECONDS - t0))s — last lines from the app:"
dc logs --no-color --tail 50 web 2>&1 | sed 's/^/    /' || true

# Rollback (§ 8.4 PLX): the previous compose file — image pinned, so it is the
# combination that was actually serving. There is something to go back to when
# the file changed with a container running; a first deploy, or a re-deploy of
# the very same run shape, has no previous state and fails loudly instead.
if [ "$HAD_PREV" = 1 ] && ! cmp -s compose.yaml "$IN/compose.yaml.prev"; then
  cp -p "$IN/compose.yaml.prev" compose.yaml
  echo "↩ rolling back to ${PREV_IMAGE:-the previous compose.yaml}"
  if dc up -d web && healthy; then
    echo "✓ rolled back to ${PREV_IMAGE:-the previous compose.yaml}"
  else
    echo "✗ rollback also unhealthy — manual intervention needed"
  fi
else
  echo "✗ nothing to roll back to (first deploy, or the same run shape re-deployed) — manual intervention needed"
fi
exit 1
REMOTE
