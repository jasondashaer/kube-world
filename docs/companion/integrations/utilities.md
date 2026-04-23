# Utility Integrations

## Wake-on-LAN (`generic-pingandwake`)

Pings a host; if not alive, sends WOL magic packet. Use for powering on computers before a service.

| Setting | Value |
|---------|-------|
| Host | Target IP |
| MAC | Target MAC address |
| Protocol | UDP port 9 (magic packet) |

**Prerequisites:** Target computer must have WOL enabled in BIOS/UEFI and network adapter settings.

## SSH Remote Control (`generic-ssh`)

Execute shell commands on remote machines. Use for graceful shutdown, app launching, status checks.

| Setting | Value |
|---------|-------|
| Host | Target IP |
| Port | 22 |
| Username/Password | SSH credentials |

```yaml
# Graceful shutdown button
- type: button
  text: "Shutdown\nシャットダウン"
  color: "#CC0000"
  actions:
    down:
      - action: ssh:send_command
        options:
          command: "sudo shutdown -h now"
```

## HTTP Requests (`generic-http`)

Send arbitrary HTTP requests. Useful for APIs without dedicated Companion modules.

## TCP/UDP (`generic-tcp-udp`)

Send raw TCP or UDP commands. Used for:
- RS-232 over TCP (projector control via serial-to-IP adapter)
- Custom protocol devices
- Simple command-response devices

## Internal: Timer (`companion-timer`)

Built-in Companion timer module. No external connection needed.

- **Start/Stop/Toggle Timer** — countdown or countup
- **Set Timer Duration** — configure time
- **Timer Feedback** — shows remaining time on button, changes color at thresholds

## Internal: Variables (`companion-variables`)

Companion's built-in variable system. Create custom variables, set values from buttons, display on buttons.

- **Set Variable** — store a value
- **Variable Feedback** — display variable value on button text
- **Math Operations** — increment/decrement variables
