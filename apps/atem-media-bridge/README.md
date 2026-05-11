# atem-media-bridge

Pi-side service that refills the ATEM Mini Pro media pool from disk so
graphics survive ATEM hard power cycles.

**Why this exists.** The bmd-atem Companion module (v4.0.1) exposes
`mediaPlayerSource` to *select* a slot but cannot *upload* stills. The
ATEM Mini Pro's media pool is volatile — slots clear on hard cycle.
Without a Pi-side refill, a power blip mid-service silently empties
the pool. This bridge stores graphics on `msn-saitama` and pushes them
into the ATEM at boot (or on demand), giving you a known-good pool
state every time the Pi or the ATEM restarts.

## How it works

1. PNG/JPG/BMP graphics live under `/opt/atem-media/` on the Pi.
2. `slots.yaml` maps each slot index to a filename + caption.
3. On systemd start (or `systemctl restart atem-media-bridge`), the
   bridge reads the YAML, encodes each image to ATEM's BGRA format
   via `atem-connection`, and uploads it to the matching slot.
4. Companion targets slots by index via the existing `mediaPlayerSource`
   action — no Companion config change needed beyond pointing at the
   right slot number.

## Slot mapping (`/etc/atem-media-bridge/slots.yaml`)

```yaml
atem_host: 10.1.1.179

# ATEM Mini Pro has 20 still slots (0-19).
slots:
  - index: 0
    name: "Welcome"
    file: welcome.png

  - index: 1
    name: "Sermon Title"
    file: sermon-title.png

  - index: 2
    name: "Pre-Service"
    file: pre-service.png
```

Files referenced by `file:` are resolved against `/opt/atem-media/`.
Missing files are logged and skipped — they don't crash the run.

## First-time install

```sh
cd apps/atem-media-bridge/vanilla
sudo ./install.sh 10.1.1.179      # ATEM IP
```

This:
- Installs Node 20+ + npm (skipped if already present from CompanionPi)
- Creates `atem-media-bridge` system user
- Drops `bridge.js` + `package.json` under `/opt/atem-media-bridge/`
- `npm install` against atem-connection
- Creates `/opt/atem-media/` (graphics dir, owned by service user)
- Writes `/etc/atem-media-bridge/slots.yaml` (sample template)
- Installs + enables `atem-media-bridge.service`

## Adding a graphic

```sh
# 1. Drop the PNG/BMP on the Pi
scp myslide.png admin@msn-saitama.tailab53c1.ts.net:/tmp/
ssh admin@msn-saitama.tailab53c1.ts.net 'sudo mv /tmp/myslide.png /opt/atem-media/welcome.png'

# 2. Edit /etc/atem-media-bridge/slots.yaml on the Pi to add the slot

# 3. Reload
ssh admin@msn-saitama.tailab53c1.ts.net 'sudo systemctl restart atem-media-bridge'

# 4. Watch it land
ssh admin@msn-saitama.tailab53c1.ts.net 'journalctl -u atem-media-bridge -f'
```

## Image specs

- Max dimensions: **1920×1080**
- Recommended format: PNG with alpha (transparency preserved on ATEM)
- Other supported: BMP (24/32-bit), JPG (no alpha)
- Files larger than 1920×1080 are rejected (the upload library would
  truncate, producing garbage on-air)

## Service control

```sh
sudo systemctl status atem-media-bridge      # is it running?
sudo systemctl restart atem-media-bridge     # re-upload all slots
sudo journalctl -u atem-media-bridge -n 50   # last 50 log lines
```

## Companion integration

Once a slot is loaded, drive it from Companion via `bmd-atem`:

```yaml
# Page 43 row 1 — show graphic on program
- row: 1
  col: 6
  style:
    text: "Welcome\n挨拶"
    bgcolor: "#004499"
  actions:
    down:
      - action: atem_saitama:mediaPlayerSource
        options:
          mediaplayer: 1            # MP1 (Mini Pro has 2 media players)
          source_still: 0           # slot 0 = Welcome (per slots.yaml)
      - action: atem_saitama:program
        options:
          input: 3001               # MP1 program input id (Mini Pro)
          mixeffect: 0              # 0 → 1 post-upgrade-script
```

`source_still` is the slot index that matches the `index:` field in
`slots.yaml`. The mediaPlayerSource action just *points* MP1/MP2 at the
slot; you still need a separate `program` action to put MP1 on air.
ATEM Mini Pro media-player input ids: MP1=3010, MP2=3020 (verify with
`atem-cli source list` if uncertain — these are model-specific).

## Reload semantics

`systemd restart` pushes all slots fresh. The bridge is idempotent —
re-uploading the same image produces the same pool state. There is no
"diff" mode in this MVP; if you want only-changed slots uploaded,
that's a follow-up.

## Caveats

- ATEM disconnects mid-upload kill that slot's data. The bridge logs
  failures per slot and continues; stale slots stay as whatever the
  ATEM had before.
- The Mini Pro's pool is volatile across hard power cycles, so plan
  for the bridge to run on every Pi boot. systemd `Restart=on-failure`
  + `After=network-online.target` covers boot order; ATEM unreachable
  at boot retries every 30 seconds for 5 minutes before giving up.
- Permissions: graphics files in `/opt/atem-media/` need to be readable
  by the `atem-media-bridge` user. The installer chown's the directory;
  if you scp in as root, run `chown atem-media-bridge:atem-media-bridge
  /opt/atem-media/<file>` after.
