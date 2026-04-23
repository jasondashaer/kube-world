# Companion Core Concepts

## Architecture

Companion is a web application that bridges physical control surfaces (Stream Deck, Touch Portal) to production equipment via network protocols. It runs as a server; the web UI at port 8000 is for configuration. The Stream Deck displays buttons defined in the config.

```
Stream Deck XL (USB) → Companion Server → Network → Equipment
                         ↑
                    Web UI (config)
```

## Key Concepts

### Connections
A connection is a configured link to a piece of equipment. Each connection uses a **module** (plugin) that speaks the device's protocol. Connections are created in the **Connections** tab.

One module can have multiple connections (e.g., two OBS instances on different computers).

### Pages
A page is a grid of buttons displayed on the Stream Deck. Stream Deck XL = 8x4 = 32 buttons per page. Pages are navigated via page-up/down buttons or explicit "go to page" actions.

### Buttons
Each button on a page has:
- **Style** — text, color, background, alignment, font size
- **Actions** — what happens when pressed/released/rotated
- **Feedbacks** — visual changes based on device state
- **Steps** — multi-step buttons (press once = action A, press again = action B)

### Actions
Actions fire on button events:
- **Press (down)** — fires when button is pressed
- **Release (up)** — fires when button is released
- **Rotate CW/CCW** — for rotary encoders (Stream Deck+)
- **Long press** — configurable hold duration

Multiple actions can fire on a single press. Actions execute in order, top to bottom.

### Feedbacks
Feedbacks change button appearance based on device state. They poll the connected device and update the button's style when conditions are met.

Example: ATEM tally feedback turns a camera button RED when that camera is live on program.

Feedbacks are layered — multiple feedbacks can apply to the same button. Later feedbacks override earlier ones.

### Variables
Variables store dynamic values from connected devices. Format: `$(connection:variable_name)`.

Example: `$(obs:scene_name)` shows the current OBS scene name.

Variables can be displayed in button text using the `$()` syntax. They update in real-time.

### Triggers
Triggers fire actions based on events WITHOUT button presses:
- **Variable change** — when a variable reaches a value
- **Timer events** — at specific times
- **Startup** — when Companion starts
- **Feedback change** — when a feedback condition changes

### Surfaces
A surface is a physical control device. Stream Deck XL is one surface. Multiple surfaces can connect to one Companion instance, each showing different pages.

## Web UI Sections

| Tab | Purpose |
|-----|---------|
| **Connections** | Add/configure equipment connections |
| **Buttons** | Design button layouts, actions, feedbacks |
| **Surfaces** | Assign pages to physical devices |
| **Triggers** | Configure event-driven automations |
| **Import/Export** | Backup/restore configurations |
| **Log** | View connection and action logs |
| **Settings** | Server settings, page count, button size |

## YAML-to-Config Workflow

The `churchSupport` repo uses YAML files as the source of truth for button configs. A converter script generates the `.companionconfig` JSON file that Companion imports.

```
YAML specs (human-readable) → yaml-to-companion.py → .companionconfig (JSON) → Import into Companion
```

This is preferable to manual UI configuration because:
- Version controlled in Git
- Reviewable diffs
- Reproducible across instances
- Bulk changes are easy
