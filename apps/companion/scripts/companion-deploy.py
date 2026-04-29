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
    """Load all YAML config files from the config directory."""
    config = {
        "connections": {},
        "pages": {},
        "triggers": {},
        "custom_variables": {},
        "parameters": {},
    }

    # Collect YAML files from both nested layout (local dev) and flat layout (in-cluster Job).
    # ConfigMap volumes flatten the directory structure — files end up in CONFIG_DIR root.
    yaml_files = set()
    yaml_files.update(glob.glob(os.path.join(CONFIG_DIR, "**/*.yaml"), recursive=True))
    yaml_files.update(glob.glob(os.path.join(CONFIG_DIR, "*.yaml")))
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

    # Convert connections to instances
    connections = yaml_config.get("connections", {})
    if isinstance(connections, dict) and "connections" in connections:
        for conn in connections["connections"]:
            if not conn.get("enabled", True):
                continue
            conn_id = conn["id"]
            companion["instances"][conn_id] = {
                "moduleInstanceType": "connection",
                "instance_type": conn["module"],
                "moduleVersionId": conn.get("version"),
                "sortOrder": conn.get("sort_order", 0),
                "label": conn["label"],
                "isFirstInit": True,
                "config": conn.get("config", {}),
                "secrets": conn.get("secrets", {}),
                "lastUpgradeIndex": conn.get("upgrade_index", -1),
                "enabled": True,
            }

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
                        control["steps"][step_key]["action_sets"][event_key] = [
                            {
                                "id": make_id(),
                                "type": "action",
                                "connectionId": a.get("action", "").split(":")[0] if ":" in a.get("action", "") else "",
                                "definitionId": a.get("action", "").split(":")[-1] if ":" in a.get("action", "") else a.get("action", ""),
                                "options": a.get("options", {}),
                            }
                            for j, a in enumerate(action_list or [])
                        ]
            else:
                # Single-step button
                control["steps"]["0"] = {
                    "action_sets": {},
                    "options": {"runWhileHeld": []},
                }
                for event, action_list in actions.items():
                    event_key = {"down": "down", "up": "up", "long_press": "2000", "double_press": "dbl", "rotate_cw": "rotate_cw", "rotate_ccw": "rotate_ccw"}.get(event, event)
                    control["steps"]["0"]["action_sets"][event_key] = [
                        {
                            "id": make_id(),
                            "type": "action",
                            "connectionId": a.get("action", "").split(":")[0] if ":" in a.get("action", "") else "",
                            "definitionId": a.get("action", "").split(":")[-1] if ":" in a.get("action", "") else a.get("action", ""),
                            "options": a.get("options", {}),
                        }
                        for j, a in enumerate(action_list or [])
                    ]

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

                feedback = {
                    "id": make_id(),
                    "type": "feedback",
                    "connectionId": fb.get("type", "").split(":")[0] if ":" in fb.get("type", "") else "",
                    "definitionId": fb.get("type", "").split(":")[-1] if ":" in fb.get("type", "") else fb.get("type", ""),
                    "options": fb.get("options", {}),
                    "style": compiled_style,
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
                control["steps"]["0"]["action_sets"][event_key] = [
                    {
                        "id": make_id(),
                        "type": "action",
                        "connectionId": a.get("action", "").split(":")[0] if ":" in a.get("action", "") else "",
                        "definitionId": a.get("action", "").split(":")[-1] if ":" in a.get("action", "") else a.get("action", ""),
                        "options": a.get("options", {}),
                    }
                    for a in (action_list or [])
                ]

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
                control["feedbacks"].append({
                    "id": make_id(),
                    "connectionId": fb.get("type", "").split(":")[0] if ":" in fb.get("type", "") else "",
                    "definitionId": fb.get("type", "").split(":")[-1] if ":" in fb.get("type", "") else fb.get("type", ""),
                    "options": fb.get("options", {}),
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
            trigger["condition"].append({
                "id": make_id(),
                "type": "feedback",
                "connectionId": cond.get("type", "").split(":")[0] if ":" in cond.get("type", "") else "",
                "definitionId": cond.get("type", "").split(":")[-1] if ":" in cond.get("type", "") else cond.get("type", ""),
                "options": cond.get("options", {}),
                "style": {},
            })

        # Actions
        for action in trigger_data.get("actions", []):
            trigger["actions"].append({
                "id": make_id(),
                "type": "action",
                "connectionId": action.get("action", "").split(":")[0] if ":" in action.get("action", "") else "",
                "definitionId": action.get("action", "").split(":")[-1] if ":" in action.get("action", "") else action.get("action", ""),
                "options": action.get("options", {}),
            })

        companion["triggers"][trigger_id] = trigger

    return companion


def _load_surface_page_map():
    """Load surface-to-page assignments from surfaces.yaml."""
    surfaces_file = os.path.join(CONFIG_DIR, "surfaces.yaml")
    if not os.path.exists(surfaces_file):
        return {}
    with open(surfaces_file) as f:
        data = yaml.safe_load(f)
    if not data or "surfaces" not in data:
        return {}
    result = {}
    for surface in data["surfaces"]:
        group_id = surface.get("group_id")
        page = surface.get("startup_page")
        if group_id and page:
            result[group_id] = page
    return result


def generate(args):
    """Generate .companionconfig from YAML sources."""
    print(f"Loading YAML configs from {CONFIG_DIR}...")
    yaml_config = load_yaml_configs()

    pages = len(yaml_config.get("pages", {}))
    connections = len(yaml_config.get("connections", {}).get("connections", []))
    print(f"  Pages: {pages}, Connections: {connections}")

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
    """Import .companionconfig to Companion via tRPC WebSocket API."""
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
        print("  Step 4/4: Executing full import...")
        import_result = send_trpc(ws, "mutation", "importExport.importFull", {
            "config": {
                "buttons": "reset-and-import",
                "surfaces": {"known": "unchanged"},
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

        # Step 5: Reassign surfaces to their startup pages
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Companion Config Deployer")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("generate", help="Generate .companionconfig from YAML")

    exp = sub.add_parser("export", help="Export live config to YAML")
    exp.add_argument("--url", default="https://companion.edge1.kubew.dev")

    imp = sub.add_parser("import", help="Import config to Companion via tRPC WebSocket")
    imp.add_argument("--url", default="https://companion.edge1.kubew.dev")
    imp.add_argument("--file", default=None, help="Path to .companionconfig file (default: generated output)")

    args = parser.parse_args()
    if args.command == "generate":
        generate(args)
    elif args.command == "export":
        export_config(args)
    elif args.command == "import":
        import_config(args)
    else:
        parser.print_help()
