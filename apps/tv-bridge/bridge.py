#!/usr/bin/env python3
"""Tiny HTTP bridge that wraps `adb` for Android TV control.

Companion calls this via the generic-http module. Endpoints map to ADB
shell commands. Companion's android-tv module's `power_off`/`power_on`
silently no-op against this Philips/KTC firmware on the
PassthroughPlayerActivity (HDMI input view), so we drive power +
input-switch via ADB key events instead.

Endpoints:
    POST /tv/wake           — KEYCODE_WAKEUP (force on)
    POST /tv/sleep          — KEYCODE_SLEEP (force off)
    POST /tv/power-toggle   — KEYCODE_POWER
    POST /tv/key/<KEYCODE>  — arbitrary keyevent (no validation; trust caller)
    POST /tv/input/<id>     — input switch via TIF passthrough URI; id ∈
                              {home, hdmi1, hdmi2, hdmi3} or raw hw id
                              (HW0/HW1/HW2/...)
    GET  /tv/state          — JSON {wakefulness, powered, current_activity}
    GET  /healthz           — 200 OK if adb reachable

Config via env:
    TV_HOST           — required, e.g. "192.168.0.13:5555"
    LISTEN_ADDR       — default ":9990"
    ADB_BIN           — default "adb"
    ANDROID_HOME      — where adb keeps its keys (~/.android by default)
    INPUT_TVINPUT     — TIF service id, default
                        "com.mediatek.tvinput/.hdmi.HDMIInputService"

ADB pairing must be done once before bridge serves traffic — see
README. After pair, the adb key under $ANDROID_HOME persists in a
mounted PVC (k3s) or /var/lib/tv-bridge/.android (vanilla).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

TV_HOST = os.environ.get("TV_HOST", "").strip()
LISTEN_ADDR = os.environ.get("LISTEN_ADDR", ":9990")
ADB_BIN = os.environ.get("ADB_BIN", "adb")
INPUT_TVINPUT = os.environ.get(
    "INPUT_TVINPUT", "com.mediatek.tvinput/.hdmi.HDMIInputService"
)

# Friendly id → HW slot mapping. The HW slot id is firmware-specific —
# adjust per TV. For Philips KTC 6700 series:
#   HW0 = first HDMI, HW1 = HDMI 1 (Sonos), HW2 = HDMI 2 (pi)
INPUT_MAP = {
    "hdmi1": "HW1",
    "hdmi2": "HW2",
    "hdmi3": "HW3",
    "hdmi0": "HW0",
}


def _adb(*args: str, timeout: float = 10.0) -> tuple[int, str, str]:
    """Run `adb -s <TV_HOST> <args>`. Returns (rc, stdout, stderr)."""
    if not TV_HOST:
        return 1, "", "TV_HOST not configured"
    cmd = [ADB_BIN, "-s", TV_HOST, *args]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"adb timeout after {timeout}s"


def _adb_connect_if_needed() -> bool:
    rc, out, _ = _adb("devices")
    if rc == 0 and TV_HOST in out and "device" in out.split(TV_HOST)[-1].split("\n")[0]:
        return True
    # Try connect
    subprocess.run([ADB_BIN, "connect", TV_HOST], capture_output=True, text=True, timeout=8)
    rc, out, _ = _adb("devices")
    return TV_HOST in out and "device" in out.split(TV_HOST)[-1].split("\n")[0]


def keyevent(keycode: str) -> tuple[int, str]:
    rc, out, err = _adb("shell", "input", "keyevent", keycode)
    return rc, err or out


def power_state() -> dict:
    rc, out, err = _adb("shell", "dumpsys power | head -40")
    if rc != 0:
        return {"error": err or "adb dumpsys failed"}
    state = {"raw": out[:1500]}
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("mWakefulness="):
            state["wakefulness"] = s.split("=", 1)[1].strip()
        elif s.startswith("mIsPowered="):
            state.setdefault("powered", s.split("=", 1)[1].strip())
    rc2, out2, _ = _adb("shell", "dumpsys activity activities | grep topResumed | head -1")
    if rc2 == 0 and out2:
        state["topResumedActivity"] = out2.strip().split("topResumedActivity=", 1)[-1][:200]
    state.pop("raw", None)  # tidy
    return state


def switch_input(input_id: str) -> tuple[int, str]:
    """Switch TV input. id can be 'home', friendly (hdmi1/hdmi2), or raw HW slot."""
    if input_id == "home":
        return _adb_to_rc(_adb("shell", "input", "keyevent", "KEYCODE_HOME"))
    hw = INPUT_MAP.get(input_id.lower(), input_id.upper())
    if not hw.startswith("HW"):
        return 2, f"unknown input id {input_id!r}"
    uri = f"content://android.media.tv/passthrough/{INPUT_TVINPUT.replace('/', '%2F')}%2F{hw}"
    rc, out, err = _adb(
        "shell",
        "am", "start",
        "-n", "com.google.android.tv.inputplayer/.player.PassthroughPlayerActivity",
        "-a", "android.intent.action.VIEW",
        "-d", uri,
    )
    return rc, err or out


def _adb_to_rc(t):
    rc, out, err = t
    return rc, err or out


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: dict | str = ""):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if isinstance(body, dict):
            body = json.dumps(body)
        if not isinstance(body, (bytes, bytearray)):
            body = body.encode("utf-8") if body else b""
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # quiet default access log
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/healthz":
            ok = _adb_connect_if_needed()
            return self._send(200 if ok else 503, {"adb": "ok" if ok else "down"})
        if path == "/tv/state":
            return self._send(200, power_state())
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        _adb_connect_if_needed()
        if path == "/tv/wake":
            rc, msg = keyevent("KEYCODE_WAKEUP")
        elif path == "/tv/sleep":
            rc, msg = keyevent("KEYCODE_SLEEP")
        elif path == "/tv/power-toggle":
            rc, msg = keyevent("KEYCODE_POWER")
        elif path.startswith("/tv/key/"):
            kc = path[len("/tv/key/"):].strip("/")
            if not kc:
                return self._send(400, {"error": "missing keycode"})
            rc, msg = keyevent(kc)
        elif path.startswith("/tv/input/"):
            iid = path[len("/tv/input/"):].strip("/")
            if not iid:
                return self._send(400, {"error": "missing input id"})
            rc, msg = switch_input(iid)
        else:
            return self._send(404, {"error": "not found"})
        return self._send(200 if rc == 0 else 502, {"rc": rc, "msg": msg.strip()[:500]})


def parse_listen(spec: str) -> tuple[str, int]:
    if ":" not in spec:
        return ("0.0.0.0", int(spec))
    host, port = spec.rsplit(":", 1)
    return (host or "0.0.0.0", int(port))


def main():
    if not TV_HOST:
        print("FATAL: TV_HOST env var required (e.g. '192.168.0.13:5555')", file=sys.stderr)
        sys.exit(2)
    host, port = parse_listen(LISTEN_ADDR)
    print(f"tv-bridge: TV_HOST={TV_HOST} listen={host}:{port} adb={ADB_BIN}", file=sys.stderr)
    # Best-effort initial connect — don't fail if TV unreachable (will retry per-request).
    _adb_connect_if_needed()
    HTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
