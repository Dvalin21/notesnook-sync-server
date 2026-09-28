#!/bin/bash
# Extract every multi-line `command:` script from docker-compose.yml and
# syntax-check the exact text the container will receive (compose turns `$$`
# into a literal `$` before handing it over).
#
# Why this exists: a one-shot service with a script syntax error blocks the
# ENTIRE stack, because every service declares
#   depends_on: <service>: condition: service_completed_successfully
# A hand-escaped double-quoted YAML scalar collapsed `exit 1` + `fi` into
# `exit 1 fi`, which would have taken the whole stack down at boot.
set -uo pipefail
cd "$(dirname "$0")/.."
COMPOSE=${1:-docker-compose.yml}
fail=0

extract() {
python3 - "$1" <<'PYEOF'
import base64, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for name, svc in d.get("services", {}).items():
    cmd = svc.get("command")
    ep = str(svc.get("entrypoint", ""))
    if not isinstance(cmd, list) or len(cmd) < 2 or cmd[0] not in ("-c", "sh", "bash"):
        continue
    script = cmd[-1] if isinstance(cmd[-1], str) else ""
    if "\n" not in script:
        continue
    joined = " ".join(map(str, cmd))
    shell = "/bin/bash" if ("bash" in ep or "bash" in joined) else "/bin/sh"
    # base64 so the script stays on ONE line: `read` splits on newlines, and a
    # multi-line script would otherwise be parsed as many separate records.
    # $$ -> $ is what compose interpolation yields inside the container.
    b64 = base64.b64encode(script.replace("$$", "$").encode()).decode()
    print("%s\t%s\t%s" % (name, shell, b64))
PYEOF
}

# Process substitution, NOT a pipe: a `while` in a pipeline runs in a subshell,
# so `fail=1` set inside it would be discarded and this script would always
# exit 0 -- a check that cannot fail is worse than no check.
while IFS=$'\t' read -r svc shell b64; do
  [ -n "${svc:-}" ] || continue
  script=$(printf '%s' "$b64" | base64 -d)
  if printf '%s\n' "$script" | "$shell" -n 2>/tmp/ccs.err; then
    printf '  OK       %s (%s)\n' "$svc" "$shell"
  else
    printf '  SYNTAX ERROR in %s (%s):\n' "$svc" "$shell"
    sed 's/^/    /' /tmp/ccs.err
    fail=1
  fi
done < <(extract "$COMPOSE")

exit "$fail"
