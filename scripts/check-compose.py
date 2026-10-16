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


def _resolve_interpolation(value: str) -> str:
    """Resolve a `${VAR}` / `${VAR:-default}` reference against .env.ci.

    Only used for the pinned-address comparison. `${VAR:?message}` is left
    as-is: compose already fails hard on an unset VAR at that point, so the
    string never reaches a comparison in practice.
    """
    import os
    import re

    env_file = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env.ci")
    vals: dict[str, str] = {}
    if os.path.exists(env_file):
        with open(env_file, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                vals[k.strip()] = v.strip()

    def sub(m: re.Match) -> str:
        body = m.group(1)
        # forms compose accepts: ${V}, ${V:-default}, ${V-default},
        # ${V:?error}, ${V?error}. The :-/:? variants are colon-separated.
        name = body
        rest = ""
        for sep in (":-", ":?", "-", "?"):
            head, found, tail = body.partition(sep)
            if found:
                name, rest = head, tail
                break
        if name in vals:
            return vals[name]
        if rest and sep != "":
            # a default was supplied -- use it
            return rest
        return m.group(0)

    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*(?:(:-|:\?|-|\?)[^}]*)?)\}", sub, value)


def load() -> dict:
    # Read piped input when there is any. `isatty()` was the wrong test: in CI
    # stdin is ALWAYS a pipe, so the old guard read empty stdin, got None, and
    # printed "OK 0 services" with exit 0. The check had never validated
    # anything, and the CI step reported success. An empty read is the real
    # signal that nobody piped anything, so fall through and run compose.
    if not sys.stdin.isatty():
        piped = sys.stdin.read()
        if piped.strip():
            return yaml.safe_load(piped) or {}
    # check=True with no stderr surfaced produces a bare traceback when compose
    # fails, which is how a caller saw "CalledProcessError" here and could not
    # tell whether the file or the environment was wrong. `--env-file .env.ci`
    # mirrors the CI step: the real .env is gitignored, and without this the
    # invocation failed on the ${S3_ACCESS_KEY:?} guard and on the new
    # ${CADDY_IP:?} guard before any check could run.
    out = subprocess.run(
        ["docker", "compose", "--env-file", ".env.ci", "config"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        print(out.stderr.strip() or out.stdout.strip(), file=sys.stderr)
        sys.exit(f"docker compose config failed (exit {out.returncode})")
    return yaml.safe_load(out.stdout) or {}


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
            # `docker compose config` emits LONG syntax (a dict) on modern
            # Compose, and short syntax (a string) on older versions and in
            # hand-written fixtures. The old code assumed str and died with
            # "'dict' object has no attribute 'split'" on the very output it
            # was supposed to be checking.
            if isinstance(v, dict):
                src = v.get("source") or ""
            else:
                src = str(v).split(":")[0]
            if src and not src.startswith((".", "/")):
                used.add(src)

    if undeclared := used - declared:
        bad.append(
            "undeclared volumes would be created EMPTY: " + ", ".join(sorted(undeclared))
        )
    if orphan := declared - used:
        bad.append("declared but never mounted: " + ", ".join(sorted(orphan)))

    # The caddy service pins an address inside the notesnook subnet. If that
    # subnet is not pinned too, the pin only works on a host where Docker
    # happens to hand out the matching pool -- and it fails with
    # "no configured subnet contains IP address ..." everywhere else, before any
    # container starts. The failure looks like a Docker bug, not a config bug,
    # which is why it is worth a gate.
    nets = d.get("networks") or {}
    for name, n in nets.items():
        svc_addr = {}
        for sname, s in services.items():
            nw = s.get("networks") or {}
            # long syntax: {name: {ipv4_address: ...}}
            if isinstance(nw, dict):
                for net, cfg in nw.items():
                    if isinstance(cfg, dict) and cfg.get("ipv4_address"):
                        # Compose interpolation (`${VAR:?err}`) survives in
                        # this path because it is applied only to the top-level
                        # `config` output. Resolve it via the CI env file so a
                        # pinned address reads as an address and not as an
                        # unparseable string.
                        addr = str(cfg["ipv4_address"])
                        # In the piped/test path compose interpolation has not run, so the value
                        # arrives as `${CADDY_IP:?...}`. Resolve it from .env.ci.
                        if "${" in addr:
                            addr = _resolve_interpolation(addr)
                        svc_addr.setdefault(net, {})[sname] = addr
        pinned = svc_addr.get(name)
        if not pinned:
            continue
        cfg = n if isinstance(n, dict) else {}
        ipam = (cfg.get("ipam") or {}).get("config") or []
        subnets = [c.get("subnet") for c in ipam if isinstance(c, dict)]
        if not subnets:
            bad.append(
                f"{name}: a service pins an IP ({', '.join(sorted(set(pinned.values())))}) "
                "but the subnet is not pinned. Docker auto-assigns 172.17.0.0/16 upward, "
                "so the pin only resolves on a host with a free matching pool."
            )
            continue
        # the pinned address must sit inside a declared subnet
        import ipaddress

        for sname, addr in sorted(pinned.items()):
            try:
                ip = ipaddress.ip_address(addr)
            except ValueError:
                bad.append(f"{name}: {sname} pins an unparseable address {addr!r}")
                continue
            if not any(
                ip in ipaddress.ip_network(s) for s in subnets if s
            ):
                bad.append(
                    f"{name}: {sname} pins {addr}, which is outside the declared "
                    f"subnet(s) {', '.join(subnets)}"
                )

    if bad:
        print("FAIL")
        for b in bad:
            print("  " + b)
        return 1

    print(f"OK  {len(services)} services, {len(declared)} volumes consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
