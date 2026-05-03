#!/usr/bin/env python3
"""
Generate a vanilla-handoff seed .companionconfig for a specific site.

Wraps companion-deploy.py generate, then optionally rewrites
connection hosts and strips kube-world-specific assumptions so the
output works on a vanilla Companion install with no K8s/cluster DNS.

Usage:
  # Generate full seed for all sites combined (development default)
  python3 seed-export.py

  # Generate site-specific seed (recommended for handoff)
  python3 seed-export.py --site yibc --output handoff/seed-yibc.companionconfig

  # Strip cluster DNS hosts and substitute LAN-equivalent hosts
  python3 seed-export.py --site yibc --rewrite-hosts \\
      --output handoff/seed-yibc.companionconfig

What gets rewritten with --rewrite-hosts:
  homeassistant: http://home-assistant.home-assistant.svc.cluster.local:8123
                 → http://homeassistant.local:8123
  Anything else with `.svc.cluster.local` → ERROR (won't silently break)

Site filtering:
  --site yibc keeps only YIBC connections + YIBC pages + Saitama
  connections marked enabled=false (so the operator sees they exist
  but they don't try to connect). Stream Decks for the other site are
  removed entirely.
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

# Import the existing generator. companion-deploy.py exposes
# load_yaml_configs + yaml_to_companionconfig.
import importlib.util
spec = importlib.util.spec_from_file_location(
    "companion_deploy",
    os.path.join(SCRIPT_DIR, "companion-deploy.py"),
)
companion_deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(companion_deploy)


# ─────────────────────────────────────────────────────────────────────
# Site filtering
# ─────────────────────────────────────────────────────────────────────

# Connection ID → site mapping. Connections with no suffix (homeassistant,
# ptz) belong to YIBC by convention.
SITE_CONNECTIONS = {
    "yibc": {
        "homeassistant", "ptz",
        "yamaha_yibc", "propresenter_yibc",
        "obs_yibc", "spotify_yibc",
    },
    "saitama": {
        "yamaha_saitama", "propresenter_saitama",
        "obs_saitama", "atem_saitama", "spotify_saitama",
    },
}

# Page numbers per site
SITE_PAGES = {
    "yibc": {20, 21, 22, 30, 31, 32},
    "saitama": {40, 41, 42, 43, 44},
}


def filter_for_site(yaml_config: dict, site: str) -> dict:
    """Keep only the connections, pages, surfaces relevant to the site.

    Other-site connections are kept but marked enabled=false so the
    operator sees the structure but they don't attempt to connect.
    """
    if site not in SITE_CONNECTIONS:
        raise ValueError(f"Unknown site: {site}")

    keep = SITE_CONNECTIONS[site]
    other = set().union(*[v for k, v in SITE_CONNECTIONS.items() if k != site])

    # Filter connections list — keep all, but disable other-site ones
    conns_doc = yaml_config.get("connections", {})
    if isinstance(conns_doc, dict) and "connections" in conns_doc:
        for c in conns_doc["connections"]:
            if c.get("id") in other:
                c["enabled"] = False
                c.setdefault("config", {})
                c["config"]["_disabled_reason"] = (
                    f"Disabled in {site} site seed — this connection "
                    "belongs to a different location."
                )

    # Filter pages — drop other-site page numbers entirely
    pages = yaml_config.get("pages", {})
    site_page_nums = SITE_PAGES.get(site, set())
    pages_to_drop = []
    for page_key, page_data in pages.items():
        page = page_data.get("page", page_data)
        num = page.get("number")
        if num is not None and num not in site_page_nums:
            pages_to_drop.append(page_key)
    for k in pages_to_drop:
        del pages[k]

    return yaml_config


# ─────────────────────────────────────────────────────────────────────
# Host rewriting (vanilla = no cluster DNS)
# ─────────────────────────────────────────────────────────────────────

# Cluster DNS → LAN-equivalent. Add entries here as we add connections
# that reference cluster services.
CLUSTER_DNS_REWRITES = {
    "home-assistant.home-assistant.svc.cluster.local":
        "homeassistant.local",
    "companion.companion.svc.cluster.local":
        "localhost",
}


def rewrite_hosts(yaml_config: dict, strict: bool = True) -> list[str]:
    """Rewrite cluster DNS hosts in connection configs.

    Returns list of warnings/errors. With strict=True, any unmapped
    .svc.cluster.local reference raises.
    """
    warnings = []
    conns_doc = yaml_config.get("connections", {})
    if isinstance(conns_doc, dict) and "connections" in conns_doc:
        for c in conns_doc["connections"]:
            cfg = c.get("config", {})
            if not isinstance(cfg, dict):
                continue
            for key, val in list(cfg.items()):
                if not isinstance(val, str):
                    continue
                replaced = val
                for src, dst in CLUSTER_DNS_REWRITES.items():
                    if src in replaced:
                        replaced = replaced.replace(src, dst)
                if replaced != val:
                    warnings.append(
                        f"  rewrote {c.get('id')}.{key}: {val} → {replaced}"
                    )
                    cfg[key] = replaced
                if "svc.cluster.local" in replaced:
                    msg = (
                        f"  UNMAPPED cluster DNS in {c.get('id')}.{key}: "
                        f"{replaced}"
                    )
                    if strict:
                        raise RuntimeError(
                            "Refusing to emit seed with unmapped cluster "
                            "DNS — vanilla install can't resolve it. "
                            "Add to CLUSTER_DNS_REWRITES.\n" + msg
                        )
                    warnings.append(msg)
    return warnings


# ─────────────────────────────────────────────────────────────────────
# Env-var substitution
# ─────────────────────────────────────────────────────────────────────

def substitute_env(yaml_config: dict, env: dict[str, str] | None = None) -> list[str]:
    """Replace ${VAR} or $VAR references in connection config values.

    Use this when generating a seed for a specific site env file —
    pre-populates connection hosts/passwords so the operator doesn't
    have to paste them in the web UI on first import.

    Returns list of substitutions made.
    """
    import re

    env = env if env is not None else dict(os.environ)
    subs = []
    pattern = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}|\$([A-Z_][A-Z0-9_]*)")

    def replace_in_value(val):
        if not isinstance(val, str):
            return val
        original = val
        result = val
        for m in pattern.finditer(val):
            var = m.group(1) or m.group(2)
            if var in env:
                result = result.replace(m.group(0), env[var])
                subs.append(f"  {var} → {env[var]!r}")
            else:
                subs.append(f"  WARN: ${var} not in env; left as-is")
        return result if result != original else val

    conns_doc = yaml_config.get("connections", {})
    if isinstance(conns_doc, dict) and "connections" in conns_doc:
        for c in conns_doc["connections"]:
            cfg = c.get("config", {})
            if isinstance(cfg, dict):
                for k, v in list(cfg.items()):
                    cfg[k] = replace_in_value(v)
            secrets = c.get("secrets", {})
            if isinstance(secrets, dict):
                for k, v in list(secrets.items()):
                    secrets[k] = replace_in_value(v)

    return subs


# ─────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawTextHelpFormatter)
    p.add_argument("--site",
                   choices=list(SITE_CONNECTIONS.keys()) + ["all"],
                   default="all",
                   help="Filter for this site (default: all)")
    p.add_argument("--output", "-o",
                   default=None,
                   help="Output path. Default: ./seed-<site>.companionconfig")
    p.add_argument("--rewrite-hosts",
                   action="store_true",
                   help="Replace cluster DNS hosts with LAN equivalents.")
    p.add_argument("--substitute-env",
                   action="store_true",
                   help="Replace ${VAR} in config values with env var values "
                        "(useful when running with `source <site>/.env`).")
    p.add_argument("--strict-host-rewrite",
                   action="store_true",
                   default=True,
                   help="Fail if an unmapped cluster DNS host remains. "
                        "Default true.")
    p.add_argument("--config-dir",
                   default=os.environ.get("COMPANION_CONFIG_DIR"),
                   help="Override config dir (else companion-deploy.py default).")
    args = p.parse_args()

    if args.config_dir:
        companion_deploy.CONFIG_DIR = args.config_dir

    print(f"Loading YAML from {companion_deploy.CONFIG_DIR}")
    yaml_config = companion_deploy.load_yaml_configs()
    print(f"  Pages: {len(yaml_config.get('pages', {}))}, "
          f"Connections: {len(yaml_config.get('connections', {}).get('connections', []))}")

    if args.site != "all":
        print(f"\nFiltering for site: {args.site}")
        before_pages = len(yaml_config.get("pages", {}))
        yaml_config = filter_for_site(yaml_config, args.site)
        after_pages = len(yaml_config.get("pages", {}))
        print(f"  Pages: {before_pages} → {after_pages}")

    if args.rewrite_hosts:
        print("\nRewriting cluster DNS hosts:")
        warnings = rewrite_hosts(yaml_config, strict=args.strict_host_rewrite)
        for w in warnings:
            print(w)
        if not warnings:
            print("  (no rewrites needed)")

    if args.substitute_env:
        print("\nSubstituting env vars:")
        subs = substitute_env(yaml_config)
        for s in subs[:50]:
            print(s)
        if len(subs) > 50:
            print(f"  ... and {len(subs) - 50} more")

    # Build companionconfig blob
    print("\nBuilding .companionconfig blob...")
    companion_config = companion_deploy.yaml_to_companionconfig(yaml_config)
    json_bytes = json.dumps(companion_config, indent=2).encode("utf-8")
    compressed = gzip.compress(json_bytes)

    output = args.output or f"seed-{args.site}.companionconfig"
    os.makedirs(os.path.dirname(os.path.abspath(output)) or ".", exist_ok=True)
    with open(output, "wb") as fh:
        fh.write(compressed)

    print(f"  Wrote {output}")
    print(f"  Compressed size: {len(compressed)} bytes")
    print(f"  Uncompressed:    {len(json_bytes)} bytes")

    json_companion = output.replace(".companionconfig", ".json")
    with open(json_companion, "w") as fh:
        json.dump(companion_config, fh, indent=2)
    print(f"  JSON: {json_companion} (for review/diff)")
    print("\nDone. Operator imports this file via Companion web UI:")
    print("  Settings → Import/Export → Import → choose this .companionconfig")


if __name__ == "__main__":
    main()
