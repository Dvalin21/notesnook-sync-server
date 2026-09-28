#!/usr/bin/env python3
"""Structural checks on the RESOLVED compose config.

Run against `docker compose config` output on stdin, or let it invoke compose
itself. These are the invariants that were violated in the wild:

  * every service carries a restart policy, log rotation and a network --
    all three come from the `x-svc` merge anchor, so a service that forgets to
    merge it silently loses all three
  * no volume is referenced without being declared. Docker auto-creates an
    undeclared volume EMPTY, which abandons the real data in the old one.
  * no declared volume is orphaned.
"""
import subprocess
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(
        "check-compose.py needs PyYAML.\n"
        "  Debian/Ubuntu: apt-get install -y python3-yaml\n"
        "  pip:           pip install pyyaml"
    )


def load() -> dict:
    if not sys.stdin.isatty():
        return yaml.safe_load(sys.stdin)
    out = subprocess.run(
        ["docker", "compose", "config"], capture_output=True, text=True, check=True
    )
    return yaml.safe_load(out.stdout)


def main() -> int:
    d = load() or {}
    services = d.get("services") or {}
    bad: list[str] = []

    for name, s in sorted(services.items()):
        if not s.get("restart"):
            bad.append(f"{name}: no restart policy")
        if not (s.get("logging") or {}).get("options"):
            bad.append(f"{name}: no log rotation (x-svc anchor not merged?)")
        if not s.get("networks"):
            bad.append(f"{name}: not attached to a network")

    declared = set(d.get("volumes") or {})
    used: set[str] = set()
    for s in services.values():
        for v in s.get("volumes") or []:
            src = v.split(":")[0]
            if not src.startswith((".", "/")):
                used.add(src)

    if undeclared := used - declared:
        bad.append(
            "undeclared volumes would be created EMPTY: " + ", ".join(sorted(undeclared))
        )
    if orphan := declared - used:
        bad.append("declared but never mounted: " + ", ".join(sorted(orphan)))

    if bad:
        print("FAIL")
        for b in bad:
            print("  " + b)
        return 1

    print(f"OK  {len(services)} services, {len(declared)} volumes consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
