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

**Setup:** Generate a long-lived access token in HA: Profile → Long-Lived Access Tokens → Create Token. Or use `./scripts/ha-mobile-token.sh`.

## Available Actions
- **Call Service** — trigger any HA service (light.turn_on, switch.toggle, etc.)
- **Toggle Entity** — toggle any entity on/off
- **Fire Event** — fire a custom HA event
- **Run Script** — execute an HA script
- **Set Input Boolean** — set helper values

## Available Feedbacks
- **Entity State** — shows current state of any entity
- **Entity Attribute** — shows specific attribute value
- **Connection Status** — connected/disconnected

## Common Button Patterns
```yaml
# Toggle a light with state feedback
- type: button
  text: "Stage\nステージ"
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
  text: "Service\n礼拝"
  color: "#0066CC"
  actions:
    down:
      - action: homeassistant:call_service
        options:
          domain: "automation"
          service: "trigger"
          entity_id: "automation.start_service_mode"
```

## Use Cases with Companion
- **Lighting scenes** — one-button recall of lighting presets (service, worship, sermon)
- **Display control** — turn on/off TVs and projectors via HA entities
- **Status monitoring** — show sensor values (temperature, occupancy) on Stream Deck buttons
- **Automation triggers** — kick off complex HA automations from physical buttons
- **Integration bridge** — use HA as middleware to control devices that don't have Companion modules

## Troubleshooting
- **Can't connect** — verify long-lived access token is valid; check HA logs
- **Entity not found** — entity_id must match exactly; check HA Developer Tools > States
- **Service fails** — verify service exists in HA Developer Tools > Services
