#!/usr/bin/env bash
#
# The verb safety baseline (Manual, "Artifact layering"), checked mechanically:
# every verb runs under strict mode and is shellcheck-clean. A remote heredoc
# (`<<'REMOTE'` … `REMOTE`) is a script of its own that shellcheck would
# otherwise see only as a string, so it is extracted and checked as one.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
for verb in scripts/*.sh; do
  grep -q '^set -euo pipefail' "$verb" || { echo "✗ $verb: missing 'set -euo pipefail'"; status=1; }
  shellcheck "$verb" || status=1
  if grep -q "<<'REMOTE'\$" "$verb"; then
    remote="$(mktemp)"
    # The heredoc's first line reads the positional args, so the extract is a
    # complete script once the shebang and strict mode are put back in front.
    { printf '#!/usr/bin/env bash\nset -euo pipefail\n'; sed -n "/<<'REMOTE'\$/,/^REMOTE\$/p" "$verb" | sed '1d;$d'; } > "$remote"
    shellcheck --shell=bash "$remote" || { echo "  ↑ in the remote heredoc of $verb"; status=1; }
    rm -f "$remote"
  fi
done
[ "$status" = 0 ] && echo "✓ verbs: strict mode present, shellcheck clean"
exit "$status"
