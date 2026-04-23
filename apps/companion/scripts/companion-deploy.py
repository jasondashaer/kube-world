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

try:
    import yaml
except ImportError:
    print("PyYAML not installed. Run: pip3 install pyyaml")
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_DIR = os.path.join(SCRIPT_DIR, "..", "config")
OUTPUT_FILE = os.path.join(SCRIPT_DIR, "..", "config", "companion.companionconfig")


def load_yaml_configs():
    """Load all YAML config files from the config directory."""
    config = {
        "connections": {},
        "pages": {},
        "triggers": {},
        "custom_variables": {},
        "parameters": {},
    }

    for yaml_file in sorted(glob.glob(os.path.join(CONFIG_DIR, "**/*.yaml"), recursive=True)):
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
        elif basename.startswith("page"):
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

    # Convert connections to instances
    connections = yaml_config.get("connections", {})
    if isinstance(connections, dict) and "connections" in connections:
        for conn in connections["connections"]:
            if not conn.get("enabled", True):
                continue
            conn_id = conn["id"]
            companion["instances"][conn_id] = {
                "instance_type": conn["module"],
                "label": conn["label"],
                "config": conn.get("config", {}),
                "enabled": True,
            }

    # Convert pages
    for page_key, page_data in yaml_config.get("pages", {}).items():
        page = page_data.get("page", page_data)
        page_id = f"page_{page_key}"

        companion_page = {
            "name": page.get("name", f"Page {page_key}"),
            "controls": {},
        }

        # Convert buttons
        for button in page_data.get("buttons", []):
            row = button.get("row", 0)
            col = button.get("col", 0)
            control_id = f"{row}/{col}"

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
                        "options": {},
                    }
                    for event, action_list in step_actions.items():
                        event_key = {"down": "down", "up": "up", "long_press": "2000", "double_press": "dbl"}.get(event, event)
                        control["steps"][step_key]["action_sets"][event_key] = [
                            {
                                "id": f"action_{i}_{j}",
                                "instance": a.get("action", "").split(":")[0] if ":" in a.get("action", "") else "",
                                "action": a.get("action", "").split(":")[-1] if ":" in a.get("action", "") else a.get("action", ""),
                                "options": a.get("options", {}),
                            }
                            for j, a in enumerate(action_list or [])
                        ]
            else:
                # Single-step button
                control["steps"]["0"] = {
                    "action_sets": {},
                    "options": {},
                }
                for event, action_list in actions.items():
                    event_key = {"down": "down", "up": "up", "long_press": "2000", "double_press": "dbl", "rotate_cw": "rotate_cw", "rotate_ccw": "rotate_ccw"}.get(event, event)
                    control["steps"]["0"]["action_sets"][event_key] = [
                        {
                            "id": f"action_0_{j}",
                            "instance": a.get("action", "").split(":")[0] if ":" in a.get("action", "") else "",
                            "action": a.get("action", "").split(":")[-1] if ":" in a.get("action", "") else a.get("action", ""),
                            "options": a.get("options", {}),
                        }
                        for j, a in enumerate(action_list or [])
                    ]

            # Feedbacks
            for fb in button.get("feedbacks", []):
                feedback = {
                    "id": f"fb_{len(control['feedbacks'])}",
                    "instance_id": fb.get("type", "").split(":")[0] if ":" in fb.get("type", "") else "",
                    "type": fb.get("type", "").split(":")[-1] if ":" in fb.get("type", "") else fb.get("type", ""),
                    "options": fb.get("options", {}),
                    "style": {},
                }
                fb_style = fb.get("style", {})
                if "bgcolor" in fb_style:
                    feedback["style"]["bgcolor"] = int(fb_style["bgcolor"].lstrip("#"), 16) if isinstance(fb_style["bgcolor"], str) else fb_style["bgcolor"]
                if "color" in fb_style:
                    feedback["style"]["color"] = int(fb_style["color"].lstrip("#"), 16) if isinstance(fb_style["color"], str) else fb_style["color"]
                if "text" in fb_style:
                    feedback["style"]["text"] = fb_style["text"]
                control["feedbacks"].append(feedback)

            companion_page["controls"][control_id] = control

        companion["pages"][page_key] = companion_page

    # Custom variables
    for var in yaml_config.get("custom_variables", {}).get("variables", []):
        companion["custom_variables"][var["name"]] = {
            "defaultValue": var.get("default", ""),
            "currentValue": var.get("default", ""),
            "persistCurrentValue": var.get("persist", False),
        }

    return companion


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
    """Import .companionconfig to Companion."""
    if not os.path.exists(OUTPUT_FILE):
        print(f"Config file not found: {OUTPUT_FILE}")
        print("Run 'generate' first.")
        sys.exit(1)

    print(f"Importing {OUTPUT_FILE} to Companion...")
    print("NOTE: Use Companion web UI Import/Export tab for now.")
    print(f"  1. Open {args.url}")
    print(f"  2. Go to Import/Export tab")
    print(f"  3. Click Import, select {OUTPUT_FILE}")
    print(f"  4. Choose Full Import")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Companion Config Deployer")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("generate", help="Generate .companionconfig from YAML")

    exp = sub.add_parser("export", help="Export live config to YAML")
    exp.add_argument("--url", default="https://companion.edge1.kubew.dev")

    imp = sub.add_parser("import", help="Import config to Companion")
    imp.add_argument("--url", default="https://companion.edge1.kubew.dev")

    args = parser.parse_args()
    if args.command == "generate":
        generate(args)
    elif args.command == "export":
        export_config(args)
    elif args.command == "import":
        import_config(args)
    else:
        parser.print_help()
