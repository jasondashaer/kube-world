#!/usr/bin/env python3
"""
Companion Configuration Deployer

Reads YAML layout definitions from apps/companion/config/ and generates
a .companionconfig file (gzipped JSON) that can be imported via:
  1. Companion's web UI (Import/Export tab)
  2. The /int/import/reset endpoint
  3. Direct copy to Companion's data directory

Also supports exporting the current live config back to YAML for
committing to Git ("sync back" workflow).

Usage:
  # Generate config from YAML layouts:
  python3 companion-deploy.py generate

  # Export current Companion config to YAML:
  python3 companion-deploy.py export --url https://companion.edge1.kubew.dev

  # Import a .companionconfig to Companion:
  python3 companion-deploy.py import --url https://companion.edge1.kubew.dev
"""

import argparse
import gzip
import json
import os
import sys
import glob
import uuid

try:
    import yaml
except ImportError:
    print("PyYAML not installed. Run: pip3 install pyyaml")
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# CONFIG_DIR resolution priority:
#   1. COMPANION_CONFIG_DIR env var (set by GitOps Job)
#   2. ./config (relative to cwd, for in-cluster Job)
#   3. ../config (relative to script, for local dev)
CONFIG_DIR = os.environ.get("COMPANION_CONFIG_DIR")
if not CONFIG_DIR:
    if os.path.isdir(os.path.join(os.getcwd(), "config")):
        CONFIG_DIR = os.path.join(os.getcwd(), "config")
    else:
        CONFIG_DIR = os.path.join(SCRIPT_DIR, "..", "config")

# OUTPUT_FILE: writable temp location in cluster, repo-local for dev
OUTPUT_FILE = os.environ.get(
    "COMPANION_OUTPUT_FILE",
    os.path.join(CONFIG_DIR, "companion.companionconfig")
    if os.access(CONFIG_DIR, os.W_OK)
    else "/tmp/companion.companionconfig"
)


def load_yaml_configs():
    """Load all YAML config files from the config directory.

    Site-aware loading via COMPANION_SITE env (or --site flag set by main()):
      - COMPANION_SITE=saitama → only walk config/sites/saitama/**/*.yaml
      - COMPANION_SITE=yibc    → only walk config/sites/yibc/**/*.yaml
      - unset (legacy / Edge1 Job) → walk config/**/*.yaml but skip
        config/sites/* subtrees so per-site bundles don't merge into the
        Edge1 GitOps import.
    """
    config = {
        "connections": {},
        "pages": {},
        "triggers": {},
        "custom_variables": {},
        "parameters": {},
    }

    site = os.environ.get("COMPANION_SITE", "").strip().lower()

    yaml_files = set()
    site_root = os.path.join(CONFIG_DIR, "sites", site) if site else None
    if site and os.path.isdir(site_root):
        # Site has its own bundle — load only that subtree.
        yaml_files.update(glob.glob(os.path.join(site_root, "**/*.yaml"), recursive=True))
        yaml_files.update(glob.glob(os.path.join(site_root, "*.yaml")))
    else:
        # Legacy: walk top-level config + nested page subdirs, but
        # skip the per-site bundles under config/sites/* so a site
        # filter applied to surfaces.yaml doesn't drag in another
        # site's connections. This is the path Edge1 takes today
        # (COMPANION_SITE=yibc but config/sites/yibc/ does not exist
        # — YIBC bits still live at the top level).
        all_yaml = set(glob.glob(os.path.join(CONFIG_DIR, "**/*.yaml"), recursive=True))
        all_yaml.update(glob.glob(os.path.join(CONFIG_DIR, "*.yaml")))
        sites_prefix = os.path.normpath(os.path.join(CONFIG_DIR, "sites")) + os.sep
        yaml_files = {p for p in all_yaml if not os.path.normpath(p).startswith(sites_prefix)}

    for yaml_file in sorted(yaml_files):
        with open(yaml_file) as f:
            data = yaml.safe_load(f)
            if data is None:
                continue

        basename = os.path.basename(yaml_file)

        if basename == "connections.yaml":
            config["connections"] = data
        elif basename == "parameters.yaml":
            config["parameters"] = data
        elif basename == "triggers.yaml":
            config["triggers"] = data
        elif basename == "variables.yaml":
            config["custom_variables"] = data
        elif "page" in basename and basename.endswith(".yaml"):
            page_data = data.get("page", data)
            page_num = page_data.get("number", basename)
            config["pages"][str(page_num)] = data

    return config


def _substitute_env_in_value(val, env, subs_log):
    """Replace ${VAR} or $VAR refs in a string value. Mutates subs_log."""
    if not isinstance(val, str):
        return val
    import re
    pattern = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}|\$([A-Z_][A-Z0-9_]*)")
    result = val
    for m in pattern.finditer(val):
        var = m.group(1) or m.group(2)
        if var in env and env[var]:
            result = result.replace(m.group(0), env[var])
            subs_log.append(f"    {var} → ({len(env[var])} chars)")
        else:
            subs_log.append(f"    {var} → MISSING (left as literal)")
    return result


def substitute_env(yaml_config, env=None):
    """Replace ${VAR} placeholders in connection config + secrets fields.

    Allows connections.yaml to reference env vars for credentials:

        config:
          host: "${OBS_HOST}"
          password: "${OBS_PASSWORD}"

    The companion-deploy Pod has these env vars populated from a
    SealedSecret-backed K8s Secret (see infrastructure/sealed-secrets).
    For vanilla mode, the env vars come from /etc/default/companion.
    For local dev, you can `source` a .env file before running.

    Missing env vars are left as literal `${VAR}` strings — Companion
    will show them in the UI so the operator notices and pastes the
    real value. NEVER fail-open by emitting a Companion config with a
    placeholder credential silently substituted to empty.

    Returns list of substitution log lines (for printing).
    """
    import os as _os
    env = env if env is not None else dict(_os.environ)
    log = []
    conns_doc = yaml_config.get("connections", {})
    if isinstance(conns_doc, dict) and "connections" in conns_doc:
        for c in conns_doc["connections"]:
            cfg = c.get("config", {})
            if isinstance(cfg, dict):
                for k in list(cfg.keys()):
                    cfg[k] = _substitute_env_in_value(cfg[k], env, log)
            secrets = c.get("secrets", {})
            if isinstance(secrets, dict):
                for k in list(secrets.keys()):
                    secrets[k] = _substitute_env_in_value(secrets[k], env, log)
    return log


# ─────────────────────────────────────────────────────────────────
# Pairing/credential preservation across re-imports
# ─────────────────────────────────────────────────────────────────
# Companion's full import does connections:reset — every connection is
# rebuilt from our YAML, blanking any state the *device* established at
# runtime (e.g. the android-tv module's Remote-v2 TLS cert exchanged
# during pairing). The YAML can't carry that cert (it's per-host,
# generated by the TV at pair time). Without preservation, every
# deploy-{yibc,saitama}.sh silently un-pairs the TV.
#
# Fix: before regenerating, snapshot these fields from the LIVE
# Companion for each connection (matched by label), then overlay them
# back onto the generated config so the cert/pairing survives import.
PRESERVE_FIELDS_BY_MODULE = {
    "android-tv": ["certificate", "certBool", "macAddress"],
}
# Populated by fetch_preserved_conn_state() before generate(); keyed
# by connection label → {field: value}.
PRESERVED_CONN_STATE = {}


def fetch_preserved_conn_state(url):
    """Snapshot preserve-listed config fields from the live Companion.

    Best-effort: on any failure (Companion down, first-ever import)
    returns silently — preservation just won't apply, which is the
    pre-existing behavior. Never blocks the deploy.
    """
    import urllib.request
    try:
        ctx = __import__("ssl").create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = __import__("ssl").CERT_NONE
        req = urllib.request.Request(url.rstrip("/") + "/int/export/full")
        with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
            data = json.loads(gzip.decompress(resp.read()))
    except Exception as ex:
        print(f"  (cert-preserve: no live state — {ex})")
        return

    count = 0
    for inst in (data.get("instances") or {}).values():
        if not isinstance(inst, dict):
            continue
        module = inst.get("moduleId") or inst.get("instance_type")
        fields = PRESERVE_FIELDS_BY_MODULE.get(module)
        if not fields:
            continue
        label = inst.get("label")
        cfg = inst.get("config") or {}
        snap = {}
        for f in fields:
            v = cfg.get(f)
            # Only preserve meaningful values — don't clobber a fresh
            # YAML default with an empty live blob.
            if v not in (None, "", {}, [], False):
                snap[f] = v
        if snap:
            PRESERVED_CONN_STATE[label] = snap
            count += 1
    if count:
        print(f"  cert-preserve: captured live pairing state for {count} connection(s)")


def load_preserved_state_from_file(path):
    """Seed PRESERVED_CONN_STATE from an on-disk backup (suspenders).

    Provides a fallback when live snapshot fails (Companion unreachable,
    connection mid-restart, etc.) or returns empty. Live state from
    fetch_preserved_conn_state() takes precedence — it runs after this
    and overwrites any overlapping label keys.
    """
    if not path or not os.path.exists(path):
        return
    try:
        with open(path, "r") as f:
            data = json.load(f)
    except Exception as ex:
        print(f"  cert-backup: could not read {path} — {ex}")
        return
    if not isinstance(data, dict):
        return
    count = 0
    for label, fields in data.items():
        if isinstance(fields, dict) and fields:
            PRESERVED_CONN_STATE[label] = dict(fields)
            count += 1
    if count:
        print(f"  cert-backup: seeded {count} connection(s) from {path}")


def save_preserved_state_to_file(url, path):
    """Refresh on-disk cert backup from the live Companion.

    Called AFTER a successful import so the file always reflects the
    latest known-good pairing state. If Companion is unreachable or
    has nothing worth preserving, the file is left untouched.
    """
    if not path:
        return
    import urllib.request
    try:
        ctx = __import__("ssl").create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = __import__("ssl").CERT_NONE
        req = urllib.request.Request(url.rstrip("/") + "/int/export/full")
        with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
            data = json.loads(gzip.decompress(resp.read()))
    except Exception as ex:
        print(f"  cert-backup: refresh skipped — {ex}")
        return

    snapshot = {}
    for inst in (data.get("instances") or {}).values():
        if not isinstance(inst, dict):
            continue
        module = inst.get("moduleId") or inst.get("instance_type")
        fields = PRESERVE_FIELDS_BY_MODULE.get(module)
        if not fields:
            continue
        label = inst.get("label")
        cfg = inst.get("config") or {}
        snap = {}
        for f in fields:
            v = cfg.get(f)
            if v not in (None, "", {}, [], False):
                snap[f] = v
        if snap and label:
            snapshot[label] = snap
    if not snapshot:
        print(f"  cert-backup: nothing to back up (no preserved fields found)")
        return
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(snapshot, f, indent=2, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    print(f"  cert-backup: wrote {len(snapshot)} connection(s) → {path} (mode 600)")


def yaml_to_companionconfig(yaml_config):
    """Convert YAML config structure to Companion's native format."""
    companion = {
        "version": 9,
        "type": "full",
        "companionBuild": "4.2.6+8823-stable",
        "pages": {},
        "triggers": {},
        "triggerCollections": [],
        "custom_variables": {},
        "customVariablesCollections": [],
        "expressionVariables": {},
        "expressionVariablesCollections": [],
        "instances": {},
        "connectionCollections": [],
        "surfaces": {},
        "surfaceGroups": {},
    }

    def make_id():
        """Generate a nanoid-style random ID matching Companion's format."""
        import random
        import string
        chars = string.ascii_letters + string.digits + "-_"
        return "".join(random.choices(chars, k=21))

    # Convert connections to instances.
    # Companion regenerates connection IDs on every import (the value we
    # provide as the dict key is replaced with a fresh runtime nanoid).
    # That breaks any entity option that references a connection by id
    # (e.g. internal:instance_custom_state.options.instance_id) — the
    # value would still point at our YAML id, not the new runtime id.
    # Workaround: we generate our OWN nanoid per YAML connection here,
    # use it as the dict key, and emit it everywhere the YAML refers to
    # the connection (action prefixes, feedback prefixes, instance_id
    # options). Companion still regenerates on import, but it walks
    # entity `connectionId` fields and rewrites them in lockstep — so
    # by the time the runtime stabilizes, our nanoid in the option
    # values has been remapped to whatever Companion picked. This is
    # the same trick the web UI relies on.
    yaml_id_to_runtime = {}
    connections = yaml_config.get("connections", {})
    if isinstance(connections, dict) and "connections" in connections:
        for conn in connections["connections"]:
            if not conn.get("enabled", True):
                continue
            yaml_id = conn["id"]
            runtime_id = make_id()
            yaml_id_to_runtime[yaml_id] = runtime_id

            conn_config = dict(conn.get("config", {}))
            # Overlay live pairing state (e.g. android-tv Remote-v2
            # cert) captured before regenerate, so connections:reset
            # doesn't silently un-pair the device. Only fields the
            # module is allowed to preserve, only when live had a
            # real value. isFirstInit stays False when we restored a
            # cert so the module re-uses it instead of re-pairing.
            # Companion sanitizes connection labels in its DB
            # ("ProPresenter (YIBC)" → "ProPresenter__YIBC_") — strip
            # everything not [A-Za-z0-9_] to underscore. Our snapshot
            # keys come from the live export and are sanitized, but
            # YAML labels are raw. Try both forms so the lookup hits
            # regardless of which side wrote the key.
            import re as _re
            raw_label = conn["label"]
            sanitized_label = _re.sub(r"[^A-Za-z0-9_]", "_", raw_label)
            preserved = (
                PRESERVED_CONN_STATE.get(raw_label)
                or PRESERVED_CONN_STATE.get(sanitized_label)
            )
            first_init = True
            if preserved and conn["module"] in PRESERVE_FIELDS_BY_MODULE:
                conn_config.update(preserved)
                first_init = False
                print(f"  cert-preserve: restored {sorted(preserved)} "
                      f"onto '{raw_label}'")

            companion["instances"][runtime_id] = {
                "moduleInstanceType": "connection",
                "instance_type": conn["module"],
                "moduleVersionId": conn.get("version"),
                "sortOrder": conn.get("sort_order", 0),
                "label": conn["label"],
                "isFirstInit": first_init,
                "config": conn_config,
                "secrets": conn.get("secrets", {}),
                "lastUpgradeIndex": conn.get("upgrade_index", -1),
                "enabled": True,
            }

    def _resolve_conn(yaml_id):
        """yaml conn id → runtime nanoid (passthrough if unknown)."""
        return yaml_id_to_runtime.get(yaml_id, yaml_id)

    # Option keys that are documented to hold a connection id reference.
    # Walked + remapped before each entity's options are emitted so
    # internal feedbacks like instance_custom_state actually match the
    # runtime nanoid we generated for the connection above.
    _CONN_REF_OPTION_KEYS = {"instance_id", "instanceId", "connection_id", "connectionId"}

    def _remap_options(opts):
        """Return a copy of `opts` with conn-ref keys translated."""
        if not isinstance(opts, dict):
            return opts
        out = {}
        for k, v in opts.items():
            if k in _CONN_REF_OPTION_KEYS and isinstance(v, str):
                out[k] = _resolve_conn(v)
            else:
                out[k] = v
        return out

    def _split_action_ref(ref):
        """yaml 'conn:def_id' → (connectionId nanoid, definitionId)."""
        if ":" in ref:
            yaml_conn, def_id = ref.split(":", 1)
            return _resolve_conn(yaml_conn), def_id
        return "", ref

    # Convert pages
    for page_key, page_data in yaml_config.get("pages", {}).items():
        page = page_data.get("page", page_data)

        companion_page = {
            "id": make_id(),
            "name": page.get("name", f"Page {page_key}"),
            "controls": {},
            "gridSize": {
                "minColumn": 0,
                "maxColumn": page.get("max_col", 7),
                "minRow": 0,
                "maxRow": page.get("max_row", 3),
            },
        }

        # Convert buttons — controls are nested: controls[row][col] = control
        for button in page_data.get("buttons", []):

            control = {
                "type": "button",
                "options": {
                    "relativeDelay": False,
                    "rotaryActions": button.get("type") == "encoder",
                },
                "style": {},
                "feedbacks": [],
                "steps": {},
            }

            # Style
            style = button.get("style", {})
            control["style"] = {
                "text": style.get("text", ""),
                "size": style.get("size", "auto"),
                "color": int(style.get("color", "#FFFFFF").lstrip("#"), 16) if isinstance(style.get("color"), str) else style.get("color", 0xFFFFFF),
                "bgcolor": int(style.get("bgcolor", "#000000").lstrip("#"), 16) if isinstance(style.get("bgcolor"), str) else style.get("bgcolor", 0),
                "alignment": style.get("alignment", "center:center"),
                "show_topbar": style.get("show_topbar", "default"),
            }

            # Actions → Steps
            actions = button.get("actions", {})
            if button.get("steps"):
                # Multi-step button
                for i, step in enumerate(button["steps"]):
                    step_key = str(i)
                    step_actions = step.get("actions", {})
                    control["steps"][step_key] = {
                        "action_sets": {},
                        "options": {"runWhileHeld": []},
                    }
                    for event, action_list in step_actions.items():
                        event_key = {"down": "down", "up": "up", "long_press": "2000", "double_press": "dbl"}.get(event, event)
                        emitted = []
                        for a in (action_list or []):
                            conn_id, def_id = _split_action_ref(a.get("action", ""))
                            emitted.append({
                                "id": make_id(),
                                "type": "action",
                                "connectionId": conn_id,
                                "definitionId": def_id,
                                "options": _remap_options(a.get("options", {})),
                            })
                        control["steps"][step_key]["action_sets"][event_key] = emitted
            else:
                # Single-step button
                control["steps"]["0"] = {
                    "action_sets": {},
                    "options": {"runWhileHeld": []},
                }
                for event, action_list in actions.items():
                    event_key = {"down": "down", "up": "up", "long_press": "2000", "double_press": "dbl", "rotate_cw": "rotate_cw", "rotate_ccw": "rotate_ccw"}.get(event, event)
                    emitted = []
                    for a in (action_list or []):
                        conn_id, def_id = _split_action_ref(a.get("action", ""))
                        emitted.append({
                            "id": make_id(),
                            "type": "action",
                            "connectionId": conn_id,
                            "definitionId": def_id,
                            "options": _remap_options(a.get("options", {})),
                        })
                    control["steps"]["0"]["action_sets"][event_key] = emitted

            # Feedbacks
            for fb in button.get("feedbacks", []):
                fb_style = fb.get("style", {})
                # Companion requires all style fields when style is non-empty
                compiled_style = {}
                if fb_style:
                    compiled_style["text"] = fb_style.get("text", "")
                    compiled_style["size"] = fb_style.get("size", "auto")
                    compiled_style["color"] = int(fb_style["color"].lstrip("#"), 16) if isinstance(fb_style.get("color"), str) else fb_style.get("color", 0xFFFFFF)
                    compiled_style["bgcolor"] = int(fb_style["bgcolor"].lstrip("#"), 16) if isinstance(fb_style.get("bgcolor"), str) else fb_style.get("bgcolor", 0)
                    compiled_style["alignment"] = fb_style.get("alignment", "center:center")
                    compiled_style["show_topbar"] = fb_style.get("show_topbar", "default")

                fb_conn, fb_def = _split_action_ref(fb.get("type", ""))
                feedback = {
                    "id": make_id(),
                    "type": "feedback",
                    "connectionId": fb_conn,
                    "definitionId": fb_def,
                    "options": _remap_options(fb.get("options", {})),
                    "style": compiled_style,
                    # Pin entity at the latest module upgradeIndex so module
                    # upgrade scripts (e.g. bmd-atem's 0->1-indexed mixeffect
                    # rewrite that wraps "1" into "1 + 1") don't mangle our
                    # already-current-form options on import. Per-module
                    # override via fb.upgrade_index.
                    "upgradeIndex": fb.get("upgrade_index", 9999),
                }
                control["feedbacks"].append(feedback)

            row = str(button.get("row", 0))
            col = str(button.get("col", 0))
            if row not in companion_page["controls"]:
                companion_page["controls"][row] = {}
            companion_page["controls"][row][col] = control

        # Convert encoders — placed at row 3 (Stream Deck+ encoder row)
        # with rotaryActions: true and rotate_left/rotate_right action sets
        encoder_row = str(page.get("encoder_row", 3))
        for enc in page_data.get("encoders", []):
            enc_col = str(enc.get("encoder", 0))
            enc_style = enc.get("style", {})
            enc_actions = enc.get("actions", {})

            control = {
                "type": "button",
                "options": {
                    "relativeDelay": False,
                    "rotaryActions": True,
                    "stepAutoProgress": True,
                },
                "style": {
                    "text": enc_style.get("text", ""),
                    "size": enc_style.get("size", "auto"),
                    "color": int(enc_style.get("color", "#FFFFFF").lstrip("#"), 16) if isinstance(enc_style.get("color"), str) else enc_style.get("color", 0xFFFFFF),
                    "bgcolor": int(enc_style.get("bgcolor", "#000000").lstrip("#"), 16) if isinstance(enc_style.get("bgcolor"), str) else enc_style.get("bgcolor", 0),
                    "alignment": enc_style.get("alignment", "center:center"),
                    "show_topbar": enc_style.get("show_topbar", "default"),
                },
                "feedbacks": [],
                "steps": {
                    "0": {
                        "action_sets": {
                            "down": [],
                            "up": [],
                            "rotate_left": [],
                            "rotate_right": [],
                        },
                        "options": {"runWhileHeld": []},
                    }
                },
            }

            # Map encoder actions: rotate_cw→rotate_right, rotate_ccw→rotate_left
            action_map = {
                "rotate_cw": "rotate_right",
                "rotate_ccw": "rotate_left",
                "down": "down",
                "up": "up",
                "long_press": "2000",
            }
            for yaml_event, action_list in enc_actions.items():
                event_key = action_map.get(yaml_event, yaml_event)
                emitted = []
                for a in (action_list or []):
                    conn_id, def_id = _split_action_ref(a.get("action", ""))
                    emitted.append({
                        "id": make_id(),
                        "type": "action",
                        "connectionId": conn_id,
                        "definitionId": def_id,
                        "options": _remap_options(a.get("options", {})),
                    })
                control["steps"]["0"]["action_sets"][event_key] = emitted

            # Encoder feedbacks
            for fb in enc.get("feedbacks", []):
                fb_style = fb.get("style", {})
                compiled_style = {}
                if fb_style:
                    compiled_style["text"] = fb_style.get("text", "")
                    compiled_style["size"] = fb_style.get("size", "auto")
                    compiled_style["color"] = int(fb_style["color"].lstrip("#"), 16) if isinstance(fb_style.get("color"), str) else fb_style.get("color", 0xFFFFFF)
                    compiled_style["bgcolor"] = int(fb_style["bgcolor"].lstrip("#"), 16) if isinstance(fb_style.get("bgcolor"), str) else fb_style.get("bgcolor", 0)
                    compiled_style["alignment"] = fb_style.get("alignment", "center:center")
                    compiled_style["show_topbar"] = fb_style.get("show_topbar", "default")
                fb_conn, fb_def = _split_action_ref(fb.get("type", ""))
                control["feedbacks"].append({
                    "id": make_id(),
                    "connectionId": fb_conn,
                    "definitionId": fb_def,
                    "options": _remap_options(fb.get("options", {})),
                    "style": compiled_style,
                })

            if encoder_row not in companion_page["controls"]:
                companion_page["controls"][encoder_row] = {}
            companion_page["controls"][encoder_row][enc_col] = control

        companion["pages"][page_key] = companion_page

    # Custom variables
    for var in yaml_config.get("custom_variables", {}).get("variables", []):
        companion["custom_variables"][var["name"]] = {
            "defaultValue": var.get("default", ""),
            "currentValue": var.get("default", ""),
            "persistCurrentValue": var.get("persist", False),
        }

    # Triggers
    for trigger_data in (yaml_config.get("triggers") or {}).get("triggers") or []:
        trigger_id = make_id()
        trigger = {
            "type": "trigger",
            "options": {
                "name": trigger_data.get("name", "Trigger"),
                "enabled": trigger_data.get("enabled", True),
                "sortOrder": trigger_data.get("sort_order", 0),
            },
            "actions": [],
            "condition": [],
            "events": [],
            "localVariables": [],
        }

        # Events
        for event in trigger_data.get("events", []):
            trigger["events"].append({
                "id": make_id(),
                "type": event.get("type"),
                "enabled": event.get("enabled", True),
                "options": event.get("options", {}),
            })

        # Conditions (feedback entities that gate the trigger)
        for cond in trigger_data.get("conditions", []):
            cond_conn, cond_def = _split_action_ref(cond.get("type", ""))
            trigger["condition"].append({
                "id": make_id(),
                "type": "feedback",
                "connectionId": cond_conn,
                "definitionId": cond_def,
                "options": _remap_options(cond.get("options", {})),
                "style": {},
            })

        # Actions
        for action in trigger_data.get("actions", []):
            act_conn, act_def = _split_action_ref(action.get("action", ""))
            trigger["actions"].append({
                "id": make_id(),
                "type": "action",
                "connectionId": act_conn,
                "definitionId": act_def,
                "options": _remap_options(action.get("options", {})),
            })

        companion["triggers"][trigger_id] = trigger

    return companion


def _site_filter():
    """Resolve the current target site for surface filtering.

    Reads COMPANION_SITE env (set per-deployment, e.g. "yibc" /
    "saitama"). If unset, returns None — caller treats as no filter
    (all surfaces propagate). Setting COMPANION_SITE on a deployed
    Companion is the supported way to scope surfaces.yaml entries
    to that site only — prevents YIBC IPs leaking into Saitama and
    vice versa.
    """
    s = os.environ.get("COMPANION_SITE", "").strip().lower()
    return s or None


def _surfaces_yaml_path():
    """Resolve surfaces.yaml location.

    With COMPANION_SITE set, prefer config/sites/<SITE>/surfaces.yaml so
    the per-site bundle is self-contained. Falls back to top-level
    config/surfaces.yaml for legacy/Edge1 layout.
    """
    site = _site_filter()
    if site:
        per_site = os.path.join(CONFIG_DIR, "sites", site, "surfaces.yaml")
        if os.path.exists(per_site):
            return per_site
    return os.path.join(CONFIG_DIR, "surfaces.yaml")


def _load_surface_page_map():
    """Load surface-to-page assignments from surfaces.yaml.

    Filters by COMPANION_SITE env if set — only returns entries whose
    `site` field matches.
    """
    surfaces_file = _surfaces_yaml_path()
    if not os.path.exists(surfaces_file):
        return {}
    with open(surfaces_file) as f:
        data = yaml.safe_load(f)
    if not data or "surfaces" not in data:
        return {}
    site = _site_filter()
    result = {}
    for surface in data["surfaces"]:
        if site and surface.get("site", "").lower() != site:
            continue
        group_id = surface.get("group_id")
        page = surface.get("startup_page")
        if group_id and page:
            result[group_id] = page
    return result


def _load_surface_outbound_list():
    """Load outbound surface entries from surfaces.yaml.

    Filters by COMPANION_SITE env if set. Each entry: {address, port,
    name, group_id}. Used by import_config to auto-add missing outbound
    entries against a fresh-PVC Companion.
    """
    surfaces_file = _surfaces_yaml_path()
    if not os.path.exists(surfaces_file):
        return []
    with open(surfaces_file) as f:
        data = yaml.safe_load(f)
    if not data or "surfaces" not in data:
        return []
    site = _site_filter()
    result = []
    for surface in data["surfaces"]:
        if site and surface.get("site", "").lower() != site:
            continue
        address = surface.get("address")
        if not address:
            continue
        result.append({
            "address": address,
            "port": surface.get("port", 5343),
            "name": surface.get("name", ""),
            "group_id": surface.get("group_id", ""),
        })
    return result


def _detect_companion_version(url):
    """Best-effort version detection — returns "4.2" / "4.3" / "5.0" / None.

    Queries /int/export/full and reads companionBuild. Falls back to
    None on failure; caller should default to the newer schema.
    """
    import urllib.request
    import gzip
    try:
        ctx = __import__("ssl").create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = __import__("ssl").CERT_NONE
        req = urllib.request.Request(url.rstrip("/") + "/int/export/full")
        with urllib.request.urlopen(req, context=ctx, timeout=8) as resp:
            data = json.loads(gzip.decompress(resp.read()))
        build = data.get("companionBuild", "")
        # Format: "4.2.6+8823-stable-..." or "5.0.0+9266-beta..."
        ver = build.split("+", 1)[0]
        return ver
    except Exception as e:
        print(f"    (version detect failed: {e})")
        return None


def _surface_instance_id(url):
    """Find the surface plugin instance nanoid for elgato-stream-deck.

    4.3 outbound add requires this. Returns None if not found —
    caller should skip outbound auto-add and warn.
    """
    import urllib.request
    import gzip
    try:
        ctx = __import__("ssl").create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = __import__("ssl").CERT_NONE
        req = urllib.request.Request(url.rstrip("/") + "/int/export/full")
        with urllib.request.urlopen(req, context=ctx, timeout=8) as resp:
            data = json.loads(gzip.decompress(resp.read()))
        for iid, ic in (data.get("surfaceInstances", {}) or {}).items():
            if ic.get("moduleId") == "elgato-stream-deck":
                return iid
    except Exception:
        pass
    return None


def generate(args):
    """Generate .companionconfig from YAML sources."""
    print(f"Loading YAML configs from {CONFIG_DIR}...")
    yaml_config = load_yaml_configs()

    pages = len(yaml_config.get("pages", {}))
    connections = len(yaml_config.get("connections", {}).get("connections", []))
    print(f"  Pages: {pages}, Connections: {connections}")

    # Env-var substitution in connection config + secrets.
    # Always-on — if a YAML field has no ${VAR} reference, this is a
    # no-op. Documenting credentials as ${VAR} placeholders is the
    # supported pattern; baking secrets into YAML is not.
    subs = substitute_env(yaml_config)
    if subs:
        print(f"  Env-var substitutions: {len(subs)}")
        for s in subs[:30]:
            print(s)
        if len(subs) > 30:
            print(f"    ... and {len(subs) - 30} more")

    companion_config = yaml_to_companionconfig(yaml_config)

    # Write compressed
    json_bytes = json.dumps(companion_config, indent=2).encode("utf-8")
    compressed = gzip.compress(json_bytes)

    with open(OUTPUT_FILE, "wb") as f:
        f.write(compressed)

    print(f"Generated: {OUTPUT_FILE}")
    print(f"  Size: {len(compressed)} bytes ({len(json_bytes)} uncompressed)")

    # Also write uncompressed JSON for Git diffing
    json_file = OUTPUT_FILE.replace(".companionconfig", ".json")
    with open(json_file, "w") as f:
        json.dump(companion_config, f, indent=2)
    print(f"  JSON: {json_file} (for Git diffs)")


def export_config(args):
    """Export current Companion config to YAML files."""
    import urllib.request
    import ssl

    url = f"{args.url}/int/export/full"
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    print(f"Exporting from {url}...")
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, context=ctx) as resp:
        compressed = resp.read()

    data = json.loads(gzip.decompress(compressed))

    # Save raw JSON for reference
    raw_file = os.path.join(CONFIG_DIR, "companion-export.json")
    with open(raw_file, "w") as f:
        json.dump(data, f, indent=2)
    print(f"  Raw export: {raw_file}")

    print(f"  Pages: {len(data.get('pages', {}))}")
    print(f"  Connections: {len(data.get('instances', {}))}")
    print(f"  Variables: {len(data.get('custom_variables', {}))}")
    print("Export complete. Review and commit to Git.")


def import_config(args):
    """Import .companionconfig to Companion via tRPC WebSocket API.

    Always regenerates from YAML first unless --file overrides. Skipping
    regen leads to stale config bugs that are hard to spot — the file
    looks valid but reflects an older revision of the YAML sources.
    """
    if not args.file:
        # Snapshot live pairing/cert state BEFORE regenerate so
        # connections:reset doesn't un-pair devices (android-tv etc.).
        # Two-tier strategy: on-disk backup file is loaded first as
        # fallback, then live fetch overlays anything still present
        # on the running Companion (live wins). If live is missing
        # (Companion down / connection broken), file alone keeps the
        # cert alive across the import.
        load_preserved_state_from_file(getattr(args, "cert_backup_file", None))
        fetch_preserved_conn_state(args.url)
        print("Regenerating .companionconfig from current YAML sources...")
        generate(args)
        print()
    config_file = args.file or OUTPUT_FILE
    if not os.path.exists(config_file):
        print(f"Config file not found: {config_file}")
        print("Run 'generate' first.")
        sys.exit(1)

    try:
        import websocket
    except ImportError:
        print("websocket-client not installed. Run: pip3 install websocket-client")
        sys.exit(1)

    import hashlib
    import base64
    import time
    import threading

    # Read the raw file
    with open(config_file, "rb") as f:
        raw_bytes = f.read()

    file_size = len(raw_bytes)
    file_sha1 = hashlib.sha1(raw_bytes).hexdigest()
    file_name = os.path.basename(config_file)

    # Parse URL — convert http(s) to ws(s)
    ws_url = args.url.replace("https://", "wss://").replace("http://", "ws://")
    ws_url = ws_url.rstrip("/") + "/trpc"

    print(f"Importing {config_file} ({file_size} bytes) to {ws_url}")
    print(f"  SHA1: {file_sha1}")

    # Track responses
    responses = {}
    response_event = threading.Event()
    current_id = {"value": 0}

    def send_trpc(ws, method, path, input_data=None):
        """Send a tRPC message and wait for response."""
        current_id["value"] += 1
        msg_id = current_id["value"]
        msg = {
            "id": msg_id,
            "method": method,
            "params": {"path": path},
        }
        if input_data is not None:
            msg["params"]["input"] = input_data

        response_event.clear()
        ws.send(json.dumps(msg))

        # Wait for response (up to 30s for parsing step)
        for _ in range(300):
            if msg_id in responses:
                resp = responses.pop(msg_id)
                if "error" in resp:
                    raise RuntimeError(f"tRPC error on {path}: {resp['error'].get('message', resp['error'])}")
                return resp.get("result", {}).get("data", resp.get("result"))
            time.sleep(0.1)
        raise TimeoutError(f"No response for {path} (id={msg_id}) within 30s")

    def on_message(ws, message):
        try:
            data = json.loads(message)
            if "id" in data:
                responses[data["id"]] = data
                response_event.set()
        except Exception:
            pass

    def on_error(ws, error):
        print(f"  WebSocket error: {error}")

    def on_open(ws):
        pass

    ws = websocket.WebSocketApp(
        ws_url,
        on_message=on_message,
        on_error=on_error,
        on_open=on_open,
    )

    # Run WebSocket in background thread
    ssl_opts = {"cert_reqs": 0} if ws_url.startswith("wss://") else {}
    ws_thread = threading.Thread(target=ws.run_forever, kwargs={"sslopt": ssl_opts} if ssl_opts else {}, daemon=True)
    ws_thread.start()
    time.sleep(3)

    if not ws.sock or not ws.sock.connected:
        print("Failed to connect to WebSocket")
        sys.exit(1)

    print("  Connected to Companion tRPC")

    try:
        # Step 1: Start upload
        print("  Step 1/4: Starting upload session...")
        result = send_trpc(ws, "mutation", "importExport.prepareImport.start", {
            "name": file_name,
            "size": file_size,
        })
        session_id = result if isinstance(result, str) else result.get("sessionId", result)
        print(f"    Session: {session_id}")

        # Step 2: Upload chunks (512KB each)
        print("  Step 2/4: Uploading config data...")
        chunk_size = 512 * 1024
        offset = 0
        while offset < file_size:
            chunk = raw_bytes[offset : offset + chunk_size]
            b64_chunk = base64.b64encode(chunk).decode("ascii")
            send_trpc(ws, "mutation", "importExport.prepareImport.uploadChunk", {
                "sessionId": session_id,
                "offset": offset,
                "data": b64_chunk,
            })
            offset += len(chunk)
            pct = min(100, int(offset / file_size * 100))
            print(f"    Uploaded {pct}%")

        # Step 3: Complete upload (triggers parsing)
        print("  Step 3/4: Completing upload + parsing...")
        summary = send_trpc(ws, "mutation", "importExport.prepareImport.complete", {
            "sessionId": session_id,
            "expectedChecksum": file_sha1,
        })
        if summary:
            # tRPC returns [null, data] tuple
            if isinstance(summary, list):
                s = next((x for x in summary if x is not None), summary[0])
            else:
                s = summary
            if isinstance(s, dict):
                print(f"    Import type: {s.get('type', 'unknown')}")
                for key in ["connections", "buttons", "customVariables", "triggers", "surfaces"]:
                    val = s.get(key)
                    if val is not None:
                        count = len(val) if isinstance(val, (list, dict)) else val
                        print(f"    {key}: {count}")
            else:
                print(f"    Summary: {s}")

        # Step 4: Execute full import
        # Schema (Companion 4.3+): zodClientImportOrResetSelection in
        # shared-lib/lib/Model/ImportExport.ts. surfaces is an object
        # with three keys (known, instances, remote). connections +
        # userconfig accept only "unchanged"|"reset" (zodResetType).
        # Other fields accept "unchanged"|"reset-and-import"|"reset".
        print("  Step 4/4: Executing full import...")
        import_result = send_trpc(ws, "mutation", "importExport.importFull", {
            "config": {
                "buttons": "reset-and-import",
                "surfaces": {
                    "known": "unchanged",
                    "instances": "unchanged",
                    "remote": "unchanged",
                },
                "triggers": "reset-and-import",
                "customVariables": "reset-and-import",
                "expressionVariables": "reset-and-import",
                "connections": "reset",
                "userconfig": "unchanged",
            }
        })
        print("  Import complete!")
        if import_result:
            print(f"    Result: {import_result}")

        # Step 5a: Auto-add outbound surface entries from surfaces.yaml
        # for fresh-PVC Companion (vanilla install OR k3s cutover with
        # empty data dir). Idempotent — skips entries already present.
        # Schema-version-aware: 4.2 uses (type, address, port, name);
        # 4.3 uses (instanceId) + saveConfig({address, port}).
        outbound_list = _load_surface_outbound_list()
        if outbound_list:
            print("  Step 5a/5: Ensuring outbound surface entries...")
            companion_ver = _detect_companion_version(args.url) or "4.3.0"
            major_minor = ".".join(companion_ver.split(".")[:2])
            print(f"    Detected Companion: {companion_ver} (using {major_minor} schema)")

            # Subscribe briefly to outbound watch to learn existing entries
            existing = {}
            try:
                ws.send(json.dumps({"id": 9000, "method": "subscription",
                                    "params": {"path": "surfaces.outbound.watch"}}))
                time.sleep(1.5)
                if 9000 in responses:
                    items = responses[9000].get("result", {}).get("data", {}).get("items", {})
                    for entry_id, entry in (items or {}).items():
                        addr = entry.get("address") or entry.get("config", {}).get("address")
                        existing[addr] = entry_id
            except Exception as ex:
                print(f"    (could not list existing outbound: {ex})")

            # 4.3-only: get the surface plugin instance id once
            instance_id = None
            if major_minor >= "4.3":
                instance_id = _surface_instance_id(args.url)
                if not instance_id:
                    print("    WARN: no elgato-stream-deck surface instance found; "
                          "skipping outbound auto-add")
                    outbound_list = []

            for ob in outbound_list:
                addr = ob["address"]
                if addr in existing:
                    print(f"    {addr}:{ob['port']} already registered; skipping")
                    continue
                try:
                    if major_minor < "4.3":
                        # 4.2 schema
                        send_trpc(ws, "mutation", "surfaces.outbound.add", {
                            "type": "elgato",
                            "address": addr,
                            "port": ob["port"],
                            "name": ob["name"] or "",
                        })
                        print(f"    added {addr}:{ob['port']} (4.2 schema)")
                    else:
                        # 4.3 schema: add then saveConfig
                        add_resp = send_trpc(ws, "mutation",
                                             "surfaces.outbound.add",
                                             {"instanceId": instance_id})
                        if not (isinstance(add_resp, dict) and add_resp.get("ok")):
                            print(f"    {addr}: add failed ({add_resp})")
                            continue
                        new_id = add_resp["id"]
                        send_trpc(ws, "mutation", "surfaces.outbound.saveConfig", {
                            "id": new_id,
                            "name": ob["name"] or f"Surface {addr}",
                            "config": {"address": addr, "port": ob["port"]},
                        })
                        print(f"    added {addr}:{ob['port']} (4.3 schema, id={new_id})")
                except Exception as ex:
                    print(f"    {addr}: outbound add failed ({ex})")

            # Give Companion a moment to establish the new connections
            # before page reassignment (which needs the surface to be
            # paired so the surface ID exists).
            time.sleep(8)

        # Step 5b: Reassign surfaces to their startup pages
        # Page IDs change on each import, so we need to update surface assignments.
        # Load the surface-to-page mapping from the YAML config.
        surface_map = _load_surface_page_map()
        if surface_map:
            print("  Step 5/5: Reassigning surface pages...")
            import urllib.request
            export_url = args.url.rstrip("/") + "/int/export/full"
            ctx = __import__("ssl").create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = __import__("ssl").CERT_NONE
            req = urllib.request.Request(export_url)
            with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
                export_data = json.loads(gzip.decompress(resp.read()))

            # Build page number -> page ID map
            page_id_map = {}
            for pk, pv in export_data.get("pages", {}).items():
                page_id_map[int(pk)] = pv.get("id")

            for group_id, page_num in surface_map.items():
                page_id = page_id_map.get(page_num)
                if not page_id:
                    print(f"    {group_id}: page {page_num} not found, skipping")
                    continue
                try:
                    for key, val in [
                        ("startup_page_id", page_id),
                        ("last_page_id", page_id),
                        ("use_last_page", False),
                    ]:
                        send_trpc(ws, "mutation", "surfaces.groupSetConfigKey", {
                            "groupId": group_id, "key": key, "value": val,
                        })
                    print(f"    {group_id} → page {page_num}")
                except Exception as ex:
                    print(f"    {group_id}: failed ({ex})")

    except Exception as e:
        print(f"  Import failed: {e}")
        # Try to abort
        try:
            send_trpc(ws, "mutation", "importExport.abort", {})
        except Exception:
            pass
        sys.exit(1)
    finally:
        ws.close()

    # Refresh on-disk cert backup from the now-imported live state so
    # the file tracks the latest known-good pairing. Runs only on
    # successful import (we'd have sys.exit'd above on failure).
    save_preserved_state_to_file(args.url, getattr(args, "cert_backup_file", None))


def cert_backup(args):
    """Standalone: snapshot live preserved fields → disk, no import."""
    save_preserved_state_to_file(args.url, args.cert_backup_file)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Companion Config Deployer")
    parser.add_argument(
        "--site",
        default=None,
        help="Restrict load to config/sites/<site>/. Sets COMPANION_SITE env "
             "for the rest of the run. Without this, legacy non-site files load.",
    )
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("generate", help="Generate .companionconfig from YAML")

    exp = sub.add_parser("export", help="Export live config to YAML")
    exp.add_argument("--url", default="https://companion.edge1.kubew.dev")

    imp = sub.add_parser("import", help="Import config to Companion via tRPC WebSocket")
    imp.add_argument("--url", default="https://companion.edge1.kubew.dev")
    imp.add_argument("--file", default=None, help="Path to .companionconfig file (default: generated output)")
    imp.add_argument(
        "--cert-backup-file",
        default=None,
        help="JSON file holding per-connection cert/pair state. Loaded as "
             "fallback before live snapshot, refreshed after successful import. "
             "Keep gitignored — contains device-specific TLS material.",
    )

    cb = sub.add_parser(
        "cert-backup",
        help="Snapshot live preserved fields (android-tv cert etc.) to a JSON file. Standalone — no import.",
    )
    cb.add_argument("--url", default="https://companion.edge1.kubew.dev")
    cb.add_argument(
        "--cert-backup-file",
        required=True,
        help="Output JSON path. Will be chmod 600.",
    )

    args = parser.parse_args()
    if args.site:
        os.environ["COMPANION_SITE"] = args.site
    if args.command == "generate":
        generate(args)
    elif args.command == "export":
        export_config(args)
    elif args.command == "import":
        import_config(args)
    elif args.command == "cert-backup":
        cert_backup(args)
    else:
        parser.print_help()
