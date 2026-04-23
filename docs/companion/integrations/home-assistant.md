# Home Assistant Integration

## Module
`homeassistant-server`

## Connection
| Setting | Value |
|---------|-------|
| Host | `ha.edge1.kubew.dev` or `192.168.0.175` (LAN) |
| Port | 8123 |
| Access Token | Long-lived access token from HA |
| Protocol | WebSocket API |

**Setup:** Generate a long-lived access token in HA: Profile > Long-Lived Access Tokens > Create Token. Or use `./scripts/ha-mobile-token.sh`.

## Available Actions (12)

### Switch / Boolean
- **set_switch** -- turn a switch entity on or off
- **input_boolean** -- set an input boolean helper to on/off

### Light Control
- **light_on** -- turn a light on (with optional color/brightness)
- **light_pct** -- set light to a specific brightness percentage (0-100)
- **adj_light_pct** -- adjust light brightness by a relative percentage (+/-)

### Script / Button / Scene
- **execute_script** -- execute an HA script entity
- **press_button** -- press a button entity (fires its action)
- **activate_scene** -- activate a scene entity

### Input Select
- **input_select_first** -- set an input_select to its first option
- **input_select_last** -- set an input_select to its last option
- **input_select_next** -- advance an input_select to the next option
- **input_select_prev** -- move an input_select to the previous option
- **input_select_set** -- set an input_select to a specific option value

### Groups
- **set_group_on** -- turn a group entity on/off

### Generic Service Call
- **call_service** -- call any HA service with domain, service, entity_id, and optional service_data JSON. This is the most flexible action and can control any domain.

## Available Feedbacks
- **Entity State** -- shows current state of any entity; style overrides when state matches a value
- **Entity Attribute** -- shows a specific attribute value; style overrides on match
- **Connection Status** -- connected/disconnected to Home Assistant

## Available Variables

Variables are dynamically generated based on entities discovered from Home Assistant.

| Variable Pattern | Description |
|-----------------|-------------|
| `$(homeassistant:entity.{id}.value)` | Current state value of any entity (e.g., `on`, `off`, `23.5`) |
| `$(homeassistant:entity.{id}.brightness)` | Brightness level for light entities (0-255) |
| `$(homeassistant:entity.{id}.attributes.{attr})` | Any attribute of any entity (e.g., `friendly_name`, `color_temp`, `unit_of_measurement`) |

### Common Entity Variable Examples
| Variable | Description |
|----------|-------------|
| `$(homeassistant:entity.light.stage_lights.value)` | Stage lights state (on/off) |
| `$(homeassistant:entity.light.stage_lights.brightness)` | Stage lights brightness (0-255) |
| `$(homeassistant:entity.sensor.sanctuary_temperature.value)` | Temperature sensor reading |
| `$(homeassistant:entity.input_select.service_mode.value)` | Current service mode selection |
| `$(homeassistant:entity.media_player.sanctuary.value)` | Media player state |
| `$(homeassistant:entity.binary_sensor.front_door.value)` | Door sensor state (on/off) |
| `$(homeassistant:entity.input_boolean.streaming_mode.value)` | Streaming mode helper state |

## Common Button Patterns
```yaml
# Toggle a light with state feedback
- type: button
  text: "Stage"
  color: "#666666"
  actions:
    down:
      - action: homeassistant:call_service
        options:
          domain: "light"
          service: "toggle"
          entity_id: "light.stage_lights"
  feedbacks:
    - type: homeassistant:entity_state
      options:
        entity_id: "light.stage_lights"
        value: "on"
      style:
        bgcolor: "#00CC00"

# Run automation
- type: button
  text: "Service"
  color: "#0066CC"
  actions:
    down:
      - action: homeassistant:call_service
        options:
          domain: "automation"
          service: "trigger"
          entity_id: "automation.start_service_mode"

# Light brightness control with encoder
- type: button
  text: "Stage\n$(homeassistant:entity.light.stage_lights.brightness)"
  color: "#333333"
  actions:
    rotate_cw:
      - action: homeassistant:adj_light_pct
        options:
          entity_id: "light.stage_lights"
          pct: 10  # +10% brightness
    rotate_ccw:
      - action: homeassistant:adj_light_pct
        options:
          entity_id: "light.stage_lights"
          pct: -10  # -10% brightness
    down:
      - action: homeassistant:call_service
        options:
          domain: "light"
          service: "toggle"
          entity_id: "light.stage_lights"
  feedbacks:
    - type: homeassistant:entity_state
      options:
        entity_id: "light.stage_lights"
        value: "on"
      style:
        bgcolor: "#00CC00"
        text: "Stage\n$(homeassistant:entity.light.stage_lights.brightness)"

# Scene activation with multi-step confirmation
- type: button
  text: "Worship\nScene"
  color: "#0066CC"
  steps:
    - style:
        text: "Worship\nScene"
        bgcolor: "#0066CC"
      actions:
        down:
          - action: homeassistant:activate_scene
            options:
              entity_id: "scene.worship_mode"

    - style:
        text: "Sermon\nScene"
        bgcolor: "#9900CC"
      actions:
        down:
          - action: homeassistant:activate_scene
            options:
              entity_id: "scene.sermon_mode"

    - style:
        text: "Post\nScene"
        bgcolor: "#006600"
      actions:
        down:
          - action: homeassistant:activate_scene
            options:
              entity_id: "scene.post_service"
          - action: companion:step_set
            options: { step: 1 }

# Input_select cycling with display -- service phase control
- type: button
  text: "Mode\n$(homeassistant:entity.input_select.service_mode.value)"
  color: "#666666"
  actions:
    down:
      - action: homeassistant:input_select_next
        options:
          entity_id: "input_select.service_mode"
    long_press:
      - action: homeassistant:input_select_first
        options:
          entity_id: "input_select.service_mode"
    rotate_cw:
      - action: homeassistant:input_select_next
        options:
          entity_id: "input_select.service_mode"
    rotate_ccw:
      - action: homeassistant:input_select_prev
        options:
          entity_id: "input_select.service_mode"
  feedbacks:
    - type: homeassistant:entity_state
      options:
        entity_id: "input_select.service_mode"
        value: "Worship"
      style:
        bgcolor: "#0066CC"
    - type: homeassistant:entity_state
      options:
        entity_id: "input_select.service_mode"
        value: "Sermon"
      style:
        bgcolor: "#9900CC"
    - type: homeassistant:entity_state
      options:
        entity_id: "input_select.service_mode"
        value: "Post-Service"
      style:
        bgcolor: "#006600"

# Generic call_service for any HA domain -- projector control
- type: button
  text: "Projector"
  color: "#666666"
  actions:
    down:
      - action: homeassistant:call_service
        options:
          domain: "media_player"
          service: "toggle"
          entity_id: "media_player.sanctuary_projector"
    long_press:
      - action: homeassistant:call_service
        options:
          domain: "media_player"
          service: "select_source"
          entity_id: "media_player.sanctuary_projector"
          service_data: '{"source": "HDMI 1"}'
  feedbacks:
    - type: homeassistant:entity_state
      options:
        entity_id: "media_player.sanctuary_projector"
        value: "on"
      style:
        bgcolor: "#00CC00"
        text: "Projector\n● ON"

# Temperature monitoring display (read-only)
- type: button
  text: "Temp\n$(homeassistant:entity.sensor.sanctuary_temperature.value) F"
  color: "#333333"
  actions:
    down: []  # Read-only display
  feedbacks:
    - type: homeassistant:entity_state
      options:
        entity_id: "binary_sensor.hvac_running"
        value: "on"
      style:
        bgcolor: "#003300"
        text: "HVAC ON\n$(homeassistant:entity.sensor.sanctuary_temperature.value) F"
```

## Use Cases with Companion
- **Lighting scenes** -- one-button recall of lighting presets (service, worship, sermon)
- **Display control** -- turn on/off TVs and projectors via HA entities
- **Status monitoring** -- show sensor values (temperature, occupancy) on Stream Deck buttons
- **Automation triggers** -- kick off complex HA automations from physical buttons
- **Integration bridge** -- use HA as middleware to control devices that don't have Companion modules
- **Input select cycling** -- cycle through service phases, camera presets, or audio modes
- **Climate control** -- adjust HVAC setpoints or fan modes from the stream deck

## Troubleshooting
- **Can't connect** -- verify long-lived access token is valid; check HA logs
- **Entity not found** -- entity_id must match exactly; check HA Developer Tools > States
- **Service fails** -- verify service exists in HA Developer Tools > Services
- **Brightness not updating** -- entity must be a light with brightness support; check attributes
- **input_select not cycling** -- verify the input_select entity has options configured
- **call_service service_data format** -- must be valid JSON string; use single quotes around the JSON
