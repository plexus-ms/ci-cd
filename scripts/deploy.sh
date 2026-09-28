#!/usr/bin/env bash
#
# Plexus deploy verb — § 8.4 PLX. A stateless procedure, not a system:
#
#   stage compose.yaml + env.schema from the invoking checkout (§ 5.2 PLX)
#   → ssh → check required keys by name against platform.env + secrets.env (§ 7.2 PLX)
#         → docker compose pull → compose run --rm migrate (if declared), both against the staged files
#         → swap the run shape into place → docker compose up -d → poll the readiness path
#         → on failure: restore the previous run shape, re-up the previous image (no pull), exit non-zero
#
# Run from a checkout of the app's SOURCE repo (§ 5.2 PLX): an app repo's CI,
# or the platform repo for third-party software the tenant merely operates.
# The app's run shape — apps/<app>/docker/compose.yaml (or apps/<app>/compose.yaml)
# and apps/<app>/env.schema — is read from there, staged on the host, and
# swapped into place only once pull and migrate have succeeded, so the compose
# file on the host always matches the image being deployed — and a failed
# deploy leaves the host exactly as it was. The platform playbook never touches
# these two files; it owns platform.env and secrets.env, this verb owns .env
# (§ 7.2 PLX).
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
# ref and the verb pulls whatever compose declares.
#
set -euo pipefail

USAGE="usage: deploy.sh <ssh-host> <tenant> <app> <image-ref|''>"
HOST="${1:?$USAGE}"
TENANT="${2:?$USAGE}"
APP="${3:?$USAGE}"
IMAGE="${4?$USAGE}"

# Overridable knobs (sane defaults for the stateless-app profile). The app dir
# mirrors the deploy playbook's layout: <deploy root>/<tenant>/<app>. An empty
# HEALTH_URL is resolved on the host from platform.env's PLEXUS_APP_PORT and
# the app's `plexus.healthz` label (§ 5.5 PLX), defaulting to /healthz.
APP_DIR="${PLEXUS_APP_DIR:-/opt/stacks/$TENANT/$APP}"
APP_SRC="${PLEXUS_APP_SRC:-apps/$APP}"
HEALTH_URL="${PLEXUS_HEALTH_URL:-}"
RETRIES="${PLEXUS_HEALTH_RETRIES:-30}"

# The run shape, from the invoking checkout (§ 5.2 PLX). compose.yaml is
# mandatory; env.schema is what the required-key check reads, so a missing one
# is reported and the check is skipped, never silently passed.
COMPOSE=""
for candidate in "$APP_SRC/docker/compose.yaml" "$APP_SRC/compose.yaml"; do
  [ -f "$candidate" ] && { COMPOSE="$candidate"; break; }
done
[ -n "$COMPOSE" ] || { echo "✗ no compose.yaml under $APP_SRC — run from the app's source repo" >&2; exit 2; }
SCHEMA=""
[ -f "$APP_SRC/env.schema" ] && SCHEMA="$APP_SRC/env.schema"

echo "→ deploying ${IMAGE:-<image pinned in compose.yaml>}"
echo "  host:    $HOST"
echo "  dir:     $APP_DIR"
echo "  compose: $COMPOSE"
echo "  schema:  ${SCHEMA:-<none — required-key check skipped>}"
echo "  health:  ${HEALTH_URL:-<resolved on host>}"

QDIR="$(printf '%q' "$APP_DIR")"

# Stage the run shape first, as one tar stream over ssh, into a verb-owned
# staging dir inside the app dir. Only the two files are named (never `.`),
# so the app dir's own mode, set by the playbook, is left alone. Nothing the
# host currently runs from is touched until the checks below have passed.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$COMPOSE" "$STAGE/compose.yaml"
[ -n "$SCHEMA" ] && cp "$SCHEMA" "$STAGE/env.schema"
# shellcheck disable=SC2046  # intentional word-split of an optional file name
tar -C "$STAGE" -cf - compose.yaml $([ -n "$SCHEMA" ] && echo env.schema) \
  | ssh -o StrictHostKeyChecking=accept-new "$HOST" \
      "rm -rf $QDIR/.incoming && mkdir -p $QDIR/.incoming && tar -xf - -C $QDIR/.incoming"

# Everything below runs on the host. Args are passed positionally (no fragile
# remote-env forwarding); the heredoc is quoted so it is not expanded locally.
# ssh flattens its argv into one space-joined string, so each arg is %q-quoted
# to survive the remote shell's re-parsing — an empty arg would vanish otherwise.
ssh -o StrictHostKeyChecking=accept-new "$HOST" bash -seuo pipefail -- \
  "$QDIR" "$(printf '%q' "$IMAGE")" \
  "$(printf '%q' "$HEALTH_URL")" "$(printf '%q' "$RETRIES")" <<'REMOTE'
APP_DIR="$1"; IMAGE="$2"; HEALTH_URL="$3"; RETRIES="$4"
cd "$APP_DIR"
IN=.incoming                 # staged run shape + rollback copies; gone on exit
trap 'rm -rf "$IN"' EXIT

# Compose env-file wiring: --env-file disables the implicit .env lookup, so
# both single-writer files are passed explicitly — .env (this verb's image ref)
# and platform.env (provisioning's bindings, § 7.2 PLX). A host provisioned
# before platform.env existed falls back to plain compose. .env must exist for
# --env-file even when no image ref is written (third-party app).
# platform.env is dotenv, not shell: the one value this verb needs is read by
# name — sourcing it would execute inventory values as code.
[ -f .env ] || : > .env
ENV_FILES=(--env-file .env)
PORT=""
if [ -f platform.env ]; then
  ENV_FILES+=(--env-file platform.env)
  PORT="$(sed -n 's/^PLEXUS_APP_PORT=//p' platform.env | tail -1)"
fi
dc()  { docker compose "${ENV_FILES[@]}" "$@"; }
# The staged compose file, read in place: relative paths (env_file) still
# resolve against the app dir, so pull and migrate run against the new run
# shape while the host keeps serving from the old one.
dci() { dc --project-directory . -f "$IN/compose.yaml" "$@"; }

# Required-key check (§ 7.2 PLX): env.schema is `KEY=value [# flags]`; a key
# flagged `required` must be provided by the platform — present by NAME in
# platform.env or secrets.env. Names only: the verb learns that a key exists,
# never what it holds. Flags are whole tokens from the two-word vocabulary;
# anything else in a trailing comment is a schema error, rejected, never
# skipped (§ 5.3 PLX). A quoted value may contain '#', so quoted values are
# dropped before the trailing comment is looked at.
if [ -f "$IN/env.schema" ]; then
  provided="$(cat platform.env secrets.env 2>/dev/null | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' || true)"
  if ! required="$(awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      eq = index($0, "=")
      if (!eq) { printf "✗ env.schema line %d: expected KEY=value\n", NR > "/dev/stderr"; err = 1; next }
      key = substr($0, 1, eq - 1); gsub(/[[:space:]]/, "", key)
      rest = substr($0, eq + 1); sub(/^[[:space:]]+/, "", rest)
      if (rest ~ /^"/)         sub(/^"([^"\\]|\\.)*"/, "", rest)
      else if (rest ~ /^\047/) sub(/^\047[^\047]*\047/, "", rest)
      hash = index(rest, "#"); if (!hash) next
      n = split(substr(rest, hash + 1), tok, /[[:space:]]+/)
      req = 0
      for (i = 1; i <= n; i++) {
        if (tok[i] == "" ) continue
        if (tok[i] == "required") req = 1
        else if (tok[i] != "secret") {
          printf "✗ env.schema line %d: unknown flag \"%s\" (flags are: required, secret; prose goes in full-line comments)\n", NR, tok[i] > "/dev/stderr"
          err = 1
        }
      }
      if (req) print key
    }
    END { if (err) exit 1 }' "$IN/env.schema")"; then
    echo "✗ env.schema is not valid (§ 5.3 PLX) — nothing was changed on the host" >&2
    exit 1
  fi
  missing=""
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qx "$key" <<<"$provided" || missing="$missing $key"
  done <<<"$required"
  if [ -n "$missing" ]; then
    echo "✗ required keys not provided by the platform:$missing" >&2
    echo "  declare them in the tenant inventory (apps[].env / apps[].secrets) and re-run the deploy playbook" >&2
    exit 1
  fi
fi

# Reality is the source of truth: read the currently-live image for rollback,
# from the run shape the host is serving right now.
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

# $1 = image ref ('' = whatever compose.yaml pins). No pull here: the new image
# was pulled above, the previous one is in the host's cache — a rollback must
# never depend on the registry answering.
up() {
  IMAGE="$1" dc up -d web
  if [ -n "$1" ]; then echo "IMAGE=$1" > .env; fi   # reproducibility cache for a manual compose up
}

# Pull → migrate (idempotent; runs only if compose.yaml declares it), both
# against the STAGED run shape: a failure here leaves the host exactly as it
# was — old compose file, old containers, old .env — and the previous release
# keeps serving.
IMAGE="$IMAGE" dci pull web
# `compose run` targets the service regardless of its profile; the --profile
# flag is only needed for the existence check, since `config --services`
# hides profiled services by default.
if IMAGE="$IMAGE" dci --profile migrate config --services 2>/dev/null | grep -qx migrate; then
  # stdin MUST be /dev/null: this whole script arrives on ssh's stdin, and
  # `compose run` is interactive by default — it would swallow the remaining
  # script text, ending the deploy after migrate with exit 0 (silent no-op:
  # `up -d web` and the health poll never run).
  IMAGE="$IMAGE" dci run --rm migrate </dev/null
fi

# Swap the run shape into place — the previous one is kept for rollback until
# this run ends. A source repo that ships no env.schema removes the host's
# copy: the check above already ran against what the source repo declares.
HAD_PREV=0
if [ -f compose.yaml ]; then cp -p compose.yaml "$IN/compose.yaml.prev"; HAD_PREV=1; fi
[ -f env.schema ] && cp -p env.schema "$IN/env.schema.prev"
mv "$IN/compose.yaml" compose.yaml
if [ -f "$IN/env.schema" ]; then mv "$IN/env.schema" env.schema; else rm -f env.schema; fi

up "$IMAGE"
t0=$SECONDS
if healthy; then
  echo "✓ ${IMAGE:-$(dc ps -q web | head -1 | xargs -r docker inspect --format '{{.Config.Image}}')} is live and healthy"
  exit 0
fi
echo "✗ healthcheck failed after $((SECONDS - t0))s"

# Rollback (§ 8.4 PLX): previous image under the previous compose file — the
# combination that was actually serving. There is something to go back to when
# a first-party app changes image (or compose) with a container running, or a
# third-party app changes its compose file; a first deploy, or a re-deploy of
# the very same run shape, has no previous state and fails loudly instead.
compose_changed=0
[ "$HAD_PREV" = 1 ] && ! cmp -s compose.yaml "$IN/compose.yaml.prev" && compose_changed=1
can_rollback=0
if [ -n "$IMAGE" ]; then
  [ -n "$PREV_IMAGE" ] && { [ "$PREV_IMAGE" != "$IMAGE" ] || [ "$compose_changed" = 1 ]; } && can_rollback=1
else
  [ "$compose_changed" = 1 ] && can_rollback=1
fi
if [ "$can_rollback" = 1 ]; then
  if [ "$HAD_PREV" = 1 ]; then
    cp -p "$IN/compose.yaml.prev" compose.yaml
    if [ -f "$IN/env.schema.prev" ]; then cp -p "$IN/env.schema.prev" env.schema; else rm -f env.schema; fi
  fi
  # A third-party app pins its image in compose.yaml: the restored file is the
  # rollback, and .env stays untouched (an image ref there would be a lie).
  rb_image="$PREV_IMAGE"; [ -n "$IMAGE" ] || rb_image=""
  echo "↩ rolling back to ${PREV_IMAGE:-<image pinned in the previous compose.yaml>}"
  if up "$rb_image" && healthy; then
    echo "✓ rolled back to ${PREV_IMAGE:-the previous compose.yaml}"
  else
    echo "✗ rollback also unhealthy — manual intervention needed"
  fi
else
  echo "✗ nothing to roll back to (first deploy, or the same run shape re-deployed) — manual intervention needed"
fi
exit 1
REMOTE
