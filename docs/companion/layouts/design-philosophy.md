# Button Layout Design Philosophy

## Core Principles

### Role-Based Pages
Each page serves one volunteer role. A slides operator sees only slide controls. An audio operator sees only mixer controls. This reduces cognitive load and training time.

### Consistent Navigation
Every page has navigation buttons in the same position:
- **[3,0]** (bottom-left) — Home/back
- **[3,6]** — Previous page in role
- **[3,7]** — Next page in role

Volunteers always know where "home" is.

### Color Language
Colors have consistent meaning across all pages:

| Color | Hex | Meaning | Examples |
|-------|-----|---------|----------|
| Red | `#CC0000` | Danger, live, mute, stop | Kill stream, mute mic, program tally |
| Green | `#00CC00` | Active, go, safe, unmute | Unmute, preview tally, connected |
| Blue | `#0066CC` | Navigation, informational | Page links, role selectors |
| Yellow | `#CCCC00` | Caution, standby, prep | Transition ready, pre-service |
| Gray | `#666666` | Inactive, disabled | Unused button, not connected |
| White | `#FFFFFF` | Status text, neutral | Labels, variable displays |

### Visual Feedback
Every actionable button has at least one feedback. Volunteers should never wonder "did that work?" The button changes color/text immediately when the action takes effect.

### Confirmation for Danger
Destructive actions (shutdown, kill stream, reset config) require two presses:
1. First press: button changes to "CONFIRM? / 確認?"
2. Second press: executes the action
3. Timeout: reverts to original state after 5 seconds

## Page Organization

### Page 1: Home
The landing page. Role selector buttons, system status, startup/shutdown controls.

```
[Status indicators across top row]
[Role selector buttons in middle rows — one per role]
[Startup/Shutdown in bottom row]
```

### Pages 2-3: Slides (ProPresenter)
- Page 2 (Core): Next/previous slide, clear, go to specific slides
- Page 3 (Extended): Playlist navigation, timer controls, stage display

### Pages 4-5: Audio (Yamaha TF)
- Page 4 (Core): Channel mutes for primary sources (pastor, worship, music)
- Page 5 (Extended): DCA groups, scene recall, bus sends

### Pages 6-7: Camera (ATEM)
- Page 6 (Core): Camera inputs with tally, auto transition, cut
- Page 7 (Extended): DSK, USK, media player, aux outputs

### Pages 8-9: Streaming (OBS)
- Page 8 (Core): Scene switching, stream start/stop, recording
- Page 9 (Extended): Source visibility, audio control, virtual camera

### Page 10: Emergency
All-systems emergency controls accessible from any role:
- Kill stream
- Fade to black (ATEM)
- Mute all (Yamaha)
- Clear slides (ProPresenter)
- Emergency announcement overlay

## Grid Layout Conventions

### Top Row (Row 0): Status & Primary Actions
High-frequency actions and status indicators. The most important controls for this role.

### Middle Rows (Rows 1-2): Work Area
The main operational buttons. Grouped logically (e.g., camera inputs, channel mutes).

### Bottom Row (Row 3): Navigation & System
Navigation buttons (home, previous, next page) and system-level controls.

### Column Conventions
- **Col 0**: Navigation/back or primary action
- **Cols 1-6**: Work area
- **Col 7**: Secondary navigation or status

## Bilingual Labels
All buttons use bilingual text:
```
Line 1: English (abbreviated, ≤8 chars)
Line 2: Japanese (日本語)
```
Product names stay English (ProPresenter, OBS, ATEM). Font size 14-18px for readability.

## Grouping Patterns

### Source Selection (Cameras, Scenes)
Horizontal row of source buttons. Active source highlighted (green=preview, red=program). Same position across pages for muscle memory.

### Mute Channels
Horizontal row matching physical mixer layout. Green=unmuted (safe), Red=muted (danger). Labels match physical mixer labels.

### Transition Controls
Grouped together: Cut, Auto, transition type selectors. Always in the same grid area across pages.
