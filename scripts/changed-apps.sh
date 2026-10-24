#!/usr/bin/env bash
#
# Plexus changed-apps verb — § 2 PLX-Release. Prints the deployable apps whose sources
# changed between two git refs, INCLUDING apps that depend on a changed workspace
# package (a packages/ui change redeploys its dependents).
#
# One app dir name per line (the dir under apps/), suitable for a CI matrix.
# Stateless: reads only git + the workspace manifests — no `pnpm install`.
#
#   ./changed-apps.sh <from-sha> [<to-sha>]   # <to> defaults to HEAD
#
# Two repo shapes (§ 2 PLX-App), told apart by the presence of a pnpm workspace:
#   - an APP repo is a pnpm workspace; pnpm walks its graph so dependents of a
#     changed package count as changed;
#   - the PLATFORM repo hosts third-party apps as bare apps/<name>/ compose
#     dirs with no workspace at all — there an app is "changed" exactly when a
#     file under its own dir changed.
#
# Bookkeeping is not source: the declaration marker and copier's answers file
# change on every train, and a change to them alone deploys nothing — an app
# whose only changed files are bookkeeping is left out in both repo shapes.
#
# Fallback — print ALL apps — when <from> is empty, all-zeros, or unknown to git
# (first push, force-push, new branch): pnpm's range filter errors on a missing
# left ref, so "can't diff" degrades to "consider everything changed", the safe
# (never-skip-a-deploy) default.
#
set -euo pipefail

FROM="${1:-}"
TO="${2:-HEAD}"

WORKSPACE=0
[ -f pnpm-workspace.yaml ] && WORKSPACE=1

BOOKKEEPING='(^|/)(PLEXUS\.md|\.copier-answers\.yml)$'
# The changed files that count, bookkeeping left out.
changed_files() { git diff --name-only "$FROM" "$TO" | grep -Ev "$BOOKKEEPING" || true; }

# "All apps": in a workspace, its members only (a package.json marks one — the
# same set the pnpm filter path can ever return; a bare dir is not buildable and
# must not enter the CI matrix). Without a workspace, every apps/<name>/ that
# carries a compose file is a deployable third-party app.
all_apps() {
  for d in apps/*/; do
    [ -d "$d" ] || continue
    if [ "$WORKSPACE" = 1 ]; then
      [ -f "$d/package.json" ] && basename "$d"
    else
      { [ -f "$d/docker/compose.yaml" ] || [ -f "$d/compose.yaml" ]; } && basename "$d"
    fi
  done
  return 0
}

# No usable base ref → deploy everything.
if [ -z "$FROM" ] || [ "$FROM" = "0000000000000000000000000000000000000000" ] \
   || ! git rev-parse --verify --quiet "$FROM^{commit}" >/dev/null; then
  all_apps
  exit 0
fi

# Platform repo: plain path diff, intersected with the deployable set.
if [ "$WORKSPACE" = 0 ]; then
  comm -12 <(all_apps | sort -u) \
           <(changed_files | awk -F/ '$1 == "apps" && NF >= 3 { print $2 }' | sort -u)
  exit 0
fi

# Nothing but bookkeeping changed: nothing to build or deploy.
[ -n "$(changed_files)" ] || exit 0

# Workspace-global inputs feed every app's build: the lockfile pins each app's
# dependency tree, root manifests/toolchain shape every install. pnpm's changed
# filter only sees files INSIDE project dirs, so a lockfile-only change (the
# shape of most Renovate bumps) would otherwise skip every build/deploy and let
# the environment drift behind the branch.
GLOBALS='^(pnpm-lock\.yaml|pnpm-workspace\.yaml|package\.json|turbo\.json|mise\.toml|\.npmrc|\.node-version)$'
if changed_files | grep -Eq "$GLOBALS"; then
  all_apps
  exit 0
fi

# pnpm does the graph work (`...` pulls in dependents); we only intersect its
# output with apps/* — `ls --parseable` prints absolute paths, so strip the repo
# root, keep apps/<name>, and de-dup. pnpm sees every file in a project dir,
# bookkeeping included, so an app it lists is kept only when a counted file
# changed under its own dir, or when something outside apps/ changed (a
# package it may depend on — pnpm's graph walk is the authority there).
outside=0
changed_files | grep -Evq '^apps/' && outside=1
pnpm --filter "...[$FROM...$TO]" ls --depth -1 --parseable \
  | sed "s#^$(pwd)/##" \
  | awk -F/ '$1 == "apps" && NF >= 2 { print $2 }' \
  | sort -u \
  | while IFS= read -r app; do
      if [ "$outside" = 1 ] || changed_files | grep -q "^apps/$app/"; then echo "$app"; fi
    done
