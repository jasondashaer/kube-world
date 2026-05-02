#!/usr/bin/env python3
"""
Metric-driven RGB monitor for Pironman 5 case LEDs.

Replaces pironman5's static RGB animation. Polls system + cluster
state every few seconds and maps to colors across the 4 case LEDs.

Layout (4 SK6812 LEDs in a row):
  LED 0 — CPU usage
  LED 1 — RAM usage
  LED 2 — CPU temperature
  LED 3 — System status (K8s if present, else internet)

Color mapping (each LED independently):
  green  : healthy
  yellow : warning
  red    : critical
  purple : data unavailable / error

Tunable thresholds at top of file. Polling cadence ~3s — fast enough
to feel live, slow enough to barely register on CPU graphs.

Designed to coexist with pironman5's OLED + fan logic. Set
`rgb_enable: false` in /opt/pironman5/.../config.json so pironman5
releases the LEDs.

Hardware: SK6812 GRB chain on SPI MOSI (GPIO10). Uses Adafruit's
NeoPixel SPI lib already installed in /opt/pironman5/venv.
"""
from __future__ import annotations

import os
import socket
import subprocess
import sys
import time

# ─────────────────────────────────────────────────────────────────
# Tunables
# ─────────────────────────────────────────────────────────────────

NUM_LEDS = 4
BRIGHTNESS = 0.4               # 0.0 – 1.0
POLL_INTERVAL_SEC = 3
INTERNET_PROBE_HOST = "1.1.1.1"
INTERNET_PROBE_TIMEOUT_SEC = 1

# (low, high) thresholds. value < low → green; low <= value < high → yellow; >= high → red.
THRESHOLDS = {
    "cpu_pct":   (50, 80),
    "ram_pct":   (70, 90),
    "temp_c":    (60, 75),
}

GREEN  = (0, 255, 0)
YELLOW = (255, 200, 0)
RED    = (255, 0, 0)
PURPLE = (128, 0, 128)
OFF    = (0, 0, 0)

# ─────────────────────────────────────────────────────────────────
# LED hardware
# ─────────────────────────────────────────────────────────────────

try:
    import board
    import neopixel_spi as neopixel
except ImportError as e:
    print(f"FATAL: NeoPixel SPI lib not importable: {e}", file=sys.stderr)
    print("Run from /opt/pironman5/venv (or install adafruit-circuitpython-neopixel-spi).",
          file=sys.stderr)
    sys.exit(1)

pixels = neopixel.NeoPixel_SPI(
    board.SPI(),
    NUM_LEDS,
    pixel_order=neopixel.GRB,
    brightness=BRIGHTNESS,
    auto_write=False,
)


# ─────────────────────────────────────────────────────────────────
# Metric collectors
# ─────────────────────────────────────────────────────────────────

_last_cpu = (0, 0)


def cpu_pct() -> float:
    global _last_cpu
    try:
        with open("/proc/stat") as f:
            parts = f.readline().split()
        # cpu user nice system idle iowait irq softirq steal
        nums = list(map(int, parts[1:9]))
        idle = nums[3] + nums[4]
        total = sum(nums)
        d_idle = idle - _last_cpu[0]
        d_total = total - _last_cpu[1]
        _last_cpu = (idle, total)
        if d_total <= 0:
            return 0.0
        return 100.0 * (1.0 - d_idle / d_total)
    except Exception:
        return -1.0


def ram_pct() -> float:
    try:
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, v = line.partition(":")
                info[k.strip()] = int(v.strip().split()[0])  # kB
        total = info["MemTotal"]
        avail = info["MemAvailable"]
        return 100.0 * (1.0 - avail / total)
    except Exception:
        return -1.0


def temp_c() -> float:
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return int(f.read().strip()) / 1000.0
    except Exception:
        return -1.0


def k8s_available() -> bool:
    """Is k3s installed locally?"""
    return os.path.exists("/etc/rancher/k3s/k3s.yaml") or \
        os.path.exists("/usr/local/bin/k3s")


def k8s_health_color() -> tuple[int, int, int]:
    """Green if all controller-owned pods Running. Yellow if some pending.
    Red if any failing.

    Filters out one-shot Job/CronJob pods — those reach terminal states
    (Error/Completed) and stay around as historical records, not live
    health signals. Restart count above a threshold also flags via
    yellow even if pod is currently Running (recent crashloop).
    """
    if not k8s_available():
        return internet_health_color()
    try:
        # Use -o wide to also get RESTART column; filter via custom format.
        # Skip CronJob-owned pods (kind=Pod with ownerReferences kind=Job).
        out = subprocess.run(
            ["k3s", "kubectl", "get", "pods", "-A",
             "-o=jsonpath={range .items[*]}"
             "{.metadata.namespace}/{.metadata.name}|"
             "{.status.phase}|"
             "{.status.containerStatuses[0].ready}|"
             "{.status.containerStatuses[0].restartCount}|"
             "{.metadata.ownerReferences[0].kind}{'\\n'}{end}"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode != 0:
            return PURPLE
        bad = 0
        warn = 0
        running_total = 0
        for line in out.stdout.strip().splitlines():
            parts = line.split("|")
            if len(parts) < 5:
                continue
            name, phase, ready, restarts, owner = parts
            # Filter out Job/CronJob historical pods
            if owner == "Job":
                continue
            # Treat Succeeded as healthy (one-shot init containers)
            if phase == "Succeeded":
                continue
            running_total += 1
            if phase == "Running" and ready == "true":
                # Recent crashloop signal: high restart count
                try:
                    if int(restarts) > 5:
                        warn += 1
                except ValueError:
                    pass
                continue
            if phase in ("Pending",):
                warn += 1
                continue
            # Anything else = failing (CrashLoopBackOff, ImagePullBackOff,
            # Failed, Unknown, Running-but-not-ready, etc.)
            bad += 1

        if bad > 0:
            return RED
        if warn > 0:
            return YELLOW
        return GREEN
    except Exception:
        return PURPLE


def internet_health_color() -> tuple[int, int, int]:
    """Ping a public anycast IP — green if reachable, red if not."""
    try:
        out = subprocess.run(
            ["ping", "-c", "1", "-W", str(INTERNET_PROBE_TIMEOUT_SEC),
             INTERNET_PROBE_HOST],
            capture_output=True, timeout=2,
        )
        return GREEN if out.returncode == 0 else RED
    except Exception:
        return PURPLE


# ─────────────────────────────────────────────────────────────────
# Color mapping
# ─────────────────────────────────────────────────────────────────

def threshold_color(value: float, key: str) -> tuple[int, int, int]:
    if value < 0:
        return PURPLE
    low, high = THRESHOLDS[key]
    if value < low:
        return GREEN
    if value < high:
        return YELLOW
    return RED


# ─────────────────────────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────────────────────────

def hostname() -> str:
    try:
        return socket.gethostname()
    except Exception:
        return "?"


SEVERITY = {OFF: -1, GREEN: 0, YELLOW: 1, RED: 2, PURPLE: 3}


def worst_of(*colors: tuple[int, int, int]) -> tuple[int, int, int]:
    """Pick the most-severe color from N inputs. PURPLE > RED > YELLOW > GREEN."""
    return max(colors, key=lambda c: SEVERITY.get(c, -1))


def main() -> None:
    print(f"[rgb-monitor] starting on {hostname()}")
    print(f"[rgb-monitor] poll interval {POLL_INTERVAL_SEC}s, brightness {BRIGHTNESS}")
    print(f"[rgb-monitor] thresholds: {THRESHOLDS}")
    print(f"[rgb-monitor] mode: all-{NUM_LEDS}-LEDs same color (worst-of metrics)")

    # First read primes the cpu_pct delta calculation
    cpu_pct()
    time.sleep(0.2)

    while True:
        try:
            cpu = cpu_pct()
            ram = ram_pct()
            temp = temp_c()
            sysc = k8s_health_color()  # falls through to internet if no k3s

            cpu_c  = threshold_color(cpu,  "cpu_pct")
            ram_c  = threshold_color(ram,  "ram_pct")
            temp_c_= threshold_color(temp, "temp_c")

            # All 4 LEDs same color = worst-of every metric. Strategy:
            # overpower the fan-mounted RGB ambient (uncontrollable
            # firmware cycling) with a unified status signal across
            # the entire SPI-controlled chain.
            unified = worst_of(cpu_c, ram_c, temp_c_, sysc)

            for i in range(NUM_LEDS):
                pixels[i] = unified
            pixels.show()

            print(f"[rgb-monitor] cpu={cpu:5.1f}% ram={ram:5.1f}% temp={temp:5.1f}C "
                  f"sys={sysc} → all={unified}")
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"[rgb-monitor] loop error: {e}", file=sys.stderr)

        time.sleep(POLL_INTERVAL_SEC)

    # Cleanup
    pixels.fill(OFF)
    pixels.show()


if __name__ == "__main__":
    main()
