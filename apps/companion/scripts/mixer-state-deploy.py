#!/usr/bin/env python3
"""
Mixer State Deployer — push declarative scene state to a Yamaha TF
mixer via RCP, then store the result to a scene slot.

Operator-run tool. NOT part of the auto-deploy chain — pushing to a live
mixer should be deliberate (after a session backup, with the equipment
ready and a known-good fallback). The auto-deploy chain only updates
Companion config; this script is the way to update mixer-side state.

Usage:
  # Validate YAML + show what would be sent without touching mixer
  python3 mixer-state-deploy.py --location yibc --scene 03-sermon --dry-run

  # Apply scene to mixer (default: store to Bank B at scene number from YAML)
  python3 mixer-state-deploy.py --location yibc --scene 03-sermon --apply

  # Override host (default reads from connections.yaml-equivalent map)
  python3 mixer-state-deploy.py --location yibc --scene 03-sermon \\
      --apply --host 192.168.1.54

  # Skip the store step (push state but don't persist as a scene)
  python3 mixer-state-deploy.py --location yibc --scene 03-sermon \\
      --apply --store-bank none

Exit codes:
  0  — success (or dry-run validation passed)
  1  — YAML / config error
  2  — connection / RCP error
  3  — mixer rejected a command (sent ERROR response)
"""
from __future__ import annotations

import argparse
import os
import socket
import sys
import time
from typing import Iterable

try:
    import yaml
except ImportError:
    print("PyYAML not installed. Run: pip3 install pyyaml", file=sys.stderr)
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG_DIR = os.environ.get(
    "COMPANION_CONFIG_DIR",
    os.path.join(SCRIPT_DIR, "..", "config"),
)

# Default mixer hosts per location. Override with --host.
LOCATION_HOSTS = {
    "yibc": "192.168.1.54",      # TF5
    "saitama": "192.168.10.30",  # TF1
}

RCP_PORT = 49280
RCP_BANK_MAP = {"A": 1, "B": 2}


# ─────────────────────────────────────────────────────────────────
# YAML scene format → RCP commands
# ─────────────────────────────────────────────────────────────────

def load_scene(location: str, scene_name: str, config_dir: str) -> dict:
    """Read a scene YAML from config/scenes/<location>/<scene_name>.yaml."""
    path = os.path.join(config_dir, "scenes", location, f"{scene_name}.yaml")
    if not os.path.exists(path):
        # Try with explicit .yaml extension stripped
        alt = os.path.join(config_dir, "scenes", location, scene_name)
        if os.path.exists(alt):
            path = alt
        else:
            raise FileNotFoundError(f"Scene file not found: {path}")
    with open(path) as f:
        data = yaml.safe_load(f)
    if not data or "scene" not in data:
        raise ValueError(f"Scene YAML missing top-level 'scene' key: {path}")
    return data


def state_to_commands(state: dict) -> list[str]:
    """Translate a 'state' block into a flat list of RCP set commands.

    Handles input channels, stereo input channels, mix buses, stereo
    master, mono master, DCAs. Each input section is optional — only
    the fields present in YAML are emitted as commands. Missing fields
    inherit the mixer's current value (NOT the previously stored
    scene's value), which is why pushing a partial state alone is not
    a complete reset — combine with a Bank B "pristine" recall first
    if you want a clean slate.
    """
    cmds: list[str] = []

    def fader(prefix: str, x: int, fader_val: int | None) -> None:
        if fader_val is not None:
            cmds.append(f"set {prefix}/Fader/Level {x} 0 {fader_val}")

    def mute(prefix: str, x: int, muted: bool | None) -> None:
        # Yamaha logic: Fader/On = 1 means UNMUTED, 0 means MUTED.
        if muted is not None:
            cmds.append(f"set {prefix}/Fader/On {x} 0 {0 if muted else 1}")

    def label(prefix: str, x: int, name: str | None) -> None:
        if name is not None:
            cmds.append(f'set {prefix}/Label/Name {x} 0 "{name}"')

    def color(prefix: str, x: int, c: int | None) -> None:
        if c is not None:
            cmds.append(f"set {prefix}/Label/Color {x} 0 {c}")

    # Input channels
    for ch in state.get("inputs", []) or []:
        x = ch["channel"]
        prefix = "MIXER:Current/InCh"
        label(prefix, x, ch.get("label"))
        color(prefix, x, ch.get("color"))
        fader(prefix, x, ch.get("fader"))
        mute(prefix, x, ch.get("mute"))
        # EQ HPF — note: YAML 1.1 reserves "on/off" as bool keywords; use
        # "enable" instead. PyYAML implements 1.1, so a key literally
        # named `on:` would parse as True — we read `enable` to avoid it.
        if "hpf" in ch:
            cmds.append(
                f"set MIXER:Current/InCh/Eq/HPF/On {x} 0 "
                f"{1 if ch['hpf'].get('enable') else 0}"
            )
            if "freq" in ch["hpf"]:
                cmds.append(
                    f"set MIXER:Current/InCh/Eq/HPF/Freq {x} 0 "
                    f"{ch['hpf']['freq']}"
                )
        # Sends to mix bus
        for send in ch.get("sends", []) or []:
            y = send["bus"]
            if "level" in send:
                cmds.append(
                    f"set MIXER:Current/InCh/ToMix/Level {x} {y} {send['level']}"
                )
            if "on" in send:
                cmds.append(
                    f"set MIXER:Current/InCh/ToMix/On {x} {y} "
                    f"{1 if send['on'] else 0}"
                )

    # Stereo input channels (Fx returns historically use FxRtnCh)
    for ch in state.get("stereo_inputs", []) or []:
        x = ch["channel"]
        prefix = "MIXER:Current/StInCh"
        label(prefix, x, ch.get("label"))
        fader(prefix, x, ch.get("fader"))
        mute(prefix, x, ch.get("mute"))

    # Mix buses
    for bus in state.get("buses", []) or []:
        x = bus["channel"]
        prefix = "MIXER:Current/Mix"
        label(prefix, x, bus.get("label"))
        fader(prefix, x, bus.get("fader"))
        mute(prefix, x, bus.get("mute"))

    # Stereo master
    if "master" in state and state["master"]:
        m = state["master"]
        prefix = "MIXER:Current/St"
        if "fader" in m:
            cmds.append(f"set {prefix}/Fader/Level 1 0 {m['fader']}")
        if "mute" in m:
            cmds.append(
                f"set {prefix}/Fader/On 1 0 {0 if m['mute'] else 1}"
            )

    # Mono master
    if "mono" in state and state["mono"]:
        m = state["mono"]
        prefix = "MIXER:Current/Mono"
        if "fader" in m:
            cmds.append(f"set {prefix}/Fader/Level 1 0 {m['fader']}")
        if "mute" in m:
            cmds.append(
                f"set {prefix}/Fader/On 1 0 {0 if m['mute'] else 1}"
            )

    # DCAs
    for dca in state.get("dcas", []) or []:
        x = dca["channel"]
        prefix = "MIXER:Current/DCA"
        label(prefix, x, dca.get("label"))
        fader(prefix, x, dca.get("fader"))
        mute(prefix, x, dca.get("mute"))

    return cmds


def store_commands(scene_num: int, bank_letter: str,
                   title: str | None = None,
                   comment: str | None = None) -> list[str]:
    """Build the scene-store sequence for a TF-series mixer.

    TF uses the dedicated `ssstore_ex` verb for scene storage (atomic +
    triggers proper notify chain) — not a `set` on the Store leaf.
    See yamaha-rcp-namespace.md §5 for verb semantics.
    """
    bank = RCP_BANK_MAP[bank_letter.upper()]
    out = [f"ssstore_ex MIXER:Lib/Bank/Scene {bank} {scene_num}"]
    if title:
        out.append(
            f'set MIXER:Lib/Bank/Scene/Title {bank} {scene_num} "{title}"'
        )
    if comment:
        out.append(
            f'set MIXER:Lib/Bank/Scene/Comment {bank} {scene_num} "{comment}"'
        )
    return out


# ─────────────────────────────────────────────────────────────────
# RCP transport
# ─────────────────────────────────────────────────────────────────

class RcpClient:
    """Thin TCP client for Yamaha TF RCP. Line-oriented ASCII protocol."""

    def __init__(self, host: str, port: int = RCP_PORT, timeout: float = 5.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock: socket.socket | None = None
        self.buf = b""

    def connect(self) -> None:
        self.sock = socket.create_connection(
            (self.host, self.port), timeout=self.timeout
        )
        self.sock.settimeout(self.timeout)

    def close(self) -> None:
        if self.sock:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def send(self, line: str) -> str:
        """Send one command, return the first response line (OK/NOTIFY/ERROR)."""
        if not self.sock:
            raise RuntimeError("not connected")
        if not line.endswith("\n"):
            line = line + "\n"
        self.sock.sendall(line.encode("utf-8"))
        return self._read_line()

    def _read_line(self) -> str:
        while b"\n" not in self.buf:
            chunk = self.sock.recv(4096)  # type: ignore[union-attr]
            if not chunk:
                raise RuntimeError("socket closed")
            self.buf += chunk
        line, _, rest = self.buf.partition(b"\n")
        self.buf = rest
        return line.decode("utf-8", errors="replace").rstrip("\r")


# ─────────────────────────────────────────────────────────────────
# Apply
# ─────────────────────────────────────────────────────────────────

def apply_scene(
    host: str,
    cmds: list[str],
    *,
    pace_seconds: float = 0.02,
    fail_on_error: bool = True,
) -> None:
    """Open RCP, send each command, log responses, close."""
    client = RcpClient(host)
    print(f"Connecting to {host}:{RCP_PORT}…", flush=True)
    try:
        client.connect()
    except (socket.timeout, OSError) as e:
        print(f"  Connection failed: {e}", file=sys.stderr)
        sys.exit(2)
    print(f"  Connected. Sending {len(cmds)} commands.")
    try:
        for i, cmd in enumerate(cmds, 1):
            try:
                resp = client.send(cmd)
            except (socket.timeout, OSError) as e:
                print(f"  [{i}/{len(cmds)}] {cmd}", file=sys.stderr)
                print(f"        IO error: {e}", file=sys.stderr)
                sys.exit(2)
            tag = "  " if resp.startswith("OK") else "!!"
            print(f"  {tag} [{i}/{len(cmds)}] {cmd}")
            print(f"        ← {resp}")
            if resp.startswith("ERROR") and fail_on_error:
                print(
                    "Aborting on first ERROR. Mixer may now be in a "
                    "partial-apply state — recall a known-good scene "
                    "to recover.",
                    file=sys.stderr,
                )
                sys.exit(3)
            if pace_seconds > 0:
                time.sleep(pace_seconds)
    finally:
        client.close()


# ─────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Yamaha TF mixer state deployer")
    p.add_argument(
        "--location",
        required=True,
        choices=sorted(LOCATION_HOSTS.keys()),
        help="Which mixer to target — selects default host.",
    )
    p.add_argument(
        "--scene",
        required=True,
        help="Scene file basename under config/scenes/<location>/ "
        "(without .yaml extension), e.g. 03-sermon",
    )
    p.add_argument(
        "--host",
        default=None,
        help="Override mixer IP (defaults to the location's documented host).",
    )
    p.add_argument(
        "--port",
        type=int,
        default=RCP_PORT,
        help=f"RCP TCP port (default {RCP_PORT}).",
    )
    p.add_argument(
        "--config-dir",
        default=DEFAULT_CONFIG_DIR,
        help="Config root (defaults to apps/companion/config).",
    )
    p.add_argument(
        "--store-bank",
        choices=["A", "B", "none"],
        default="B",
        help="Bank to store the resulting state into. Default 'B' "
        "(reserved for code-pushed canonical scenes; engineers own "
        "Bank A). 'none' skips the store step.",
    )
    p.add_argument(
        "--scene-number",
        type=int,
        default=None,
        help="Override the scene number to store at "
        "(default: scene.number from the YAML).",
    )

    grp = p.add_mutually_exclusive_group(required=True)
    grp.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate + print commands. No mixer connection.",
    )
    grp.add_argument(
        "--apply",
        action="store_true",
        help="Connect to mixer + send commands.",
    )

    return p.parse_args()


def main() -> int:
    args = parse_args()

    try:
        scene_doc = load_scene(args.location, args.scene, args.config_dir)
    except (FileNotFoundError, ValueError) as e:
        print(f"YAML error: {e}", file=sys.stderr)
        return 1

    scene = scene_doc["scene"]
    state = scene_doc.get("state", {})
    print(f"Scene  : {scene.get('name', '<unnamed>')}")
    print(f"Number : {scene.get('number')}  Bank (intent): "
          f"{scene.get('bank', '?')}")
    print(f"File   : config/scenes/{args.location}/{args.scene}.yaml")

    cmds = state_to_commands(state)
    if not cmds:
        print("(no state commands generated — YAML 'state' block is empty)")
    else:
        print(f"\n{len(cmds)} state command(s):")
        for c in cmds:
            print(f"  {c}")

    # Append store sequence if requested
    store_bank = args.store_bank
    scene_num = args.scene_number or scene.get("number")
    if store_bank != "none":
        if scene_num is None:
            print(
                "ERROR: --store-bank is set but no scene number provided "
                "(YAML 'scene.number' missing and no --scene-number).",
                file=sys.stderr,
            )
            return 1
        store_seq = store_commands(
            scene_num,
            store_bank,
            title=scene.get("name"),
            comment=scene.get("description"),
        )
        cmds.extend(store_seq)
        print(f"\nStore sequence ({len(store_seq)} commands):")
        for c in store_seq:
            print(f"  {c}")
    else:
        print("\nStore step skipped (--store-bank none)")

    if args.dry_run:
        print("\n--dry-run — no mixer contact. Validation OK.")
        return 0

    host = args.host or LOCATION_HOSTS[args.location]
    print(f"\nApplying to {args.location} mixer at {host}…")
    apply_scene(host, cmds)
    print("\nDone.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
