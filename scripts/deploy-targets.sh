#!/usr/bin/env bash
#
# Plexus deploy-targets verb — § 3 PLX-Platform. Prints, as one JSON object,
# where the deploy verb reaches each app a platform repo operates: the
# `plexus_deploy_target` (ssh://<deploy user>@<address>[:<port>]) of the
# inventory file whose `plexus_apps` declares the app — host_vars for a VM,
# group_vars for a group. An app whose file carries no target is left out, so
# the mount falls back to one DEPLOY_HOST for it.
#
# Stateless, and no YAML library: the two keys are read at the top level of
# each file by awk, which is enough for inventory files laid out as the
# platform preset writes them (a top-level `plexus_apps:` list of records,
# each starting with `- name:`).
#
#   ./deploy-targets.sh [<inventory dir>]    # default: inventory
#
set -euo pipefail
inv="${1:-inventory}"
[ -d "$inv" ] || { echo "✗ no inventory directory at $inv" >&2; exit 2; }
files=()
for f in "$inv"/group_vars/*.yml "$inv"/host_vars/*.yml; do [ -f "$f" ] && files+=("$f"); done
[ "${#files[@]}" -gt 0 ] || { echo '{}'; exit 0; }
awk '
  FNR == 1 { target = ""; inapps = 0; napps = 0 }
  /^plexus_deploy_target:/ { target = $2; gsub(/^["'\'']|["'\'']$/, "", target) }
  /^plexus_apps:/ { inapps = 1; next }
  inapps && /^[^ #-]/ { inapps = 0 }                     # the next top-level key ends the list
  inapps && /^ *- *name:/ { sub(/^ *- *name: */, ""); gsub(/^["'\'']|["'\'']$/, ""); apps[FILENAME, ++napps] = $0; count[FILENAME] = napps }
  { t[FILENAME] = target }
  END {
    printf "{"; sep = ""
    for (f in count) if (t[f] != "") for (i = 1; i <= count[f]; i++) { printf "%s\"%s\":\"%s\"", sep, apps[f, i], t[f]; sep = "," }
    print "}"
  }
' "${files[@]}"
