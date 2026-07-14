#!/usr/bin/env bash
#
# Plexus changed-apps verb — § 8.2 PLX. Prints the deployable apps whose sources
# changed between two git refs, INCLUDING apps that depend on a changed workspace
# package (a packages/ui change redeploys its dependents).
#
# One app dir name per line (the dir under apps/), suitable for a CI matrix.
# Stateless: reads only git + the workspace manifests — no `pnpm install`.
#
#   ./changed-apps.sh <from-sha> [<to-sha>]   # <to> defaults to HEAD
#
# Fallback — print ALL apps — when <from> is empty, all-zeros, or unknown to git
# (first push, force-push, new branch): pnpm's range filter errors on a missing
# left ref, so "can't diff" degrades to "consider everything changed", the safe
# (never-skip-a-deploy) default.
#
set -euo pipefail

FROM="${1:-}"
TO="${2:-HEAD}"

all_apps() { for d in apps/*/; do [ -d "$d" ] && basename "$d"; done; }

# No usable base ref → deploy everything.
if [ -z "$FROM" ] || [ "$FROM" = "0000000000000000000000000000000000000000" ] \
   || ! git rev-parse --verify --quiet "$FROM^{commit}" >/dev/null; then
  all_apps
  exit 0
fi

# pnpm does the graph work (`...` pulls in dependents); we only intersect its
# output with apps/* — `ls --parseable` prints absolute paths, so strip the repo
# root, keep apps/<name>, and de-dup.
pnpm --filter "...[$FROM...$TO]" ls --depth -1 --parseable \
  | sed "s#^$(pwd)/##" \
  | awk -F/ '$1 == "apps" && NF >= 2 { print $2 }' \
  | sort -u
