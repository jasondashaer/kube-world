# Utility Integrations

## Ping and Wake-on-LAN (`generic-pingandwake`)

Pings a host; if not alive, sends WOL magic packet. Use for powering on computers before a service.

### Connection
| Setting | Value |
|---------|-------|
| Host | Target IP |
| MAC | Target MAC address |
| Protocol | UDP port 9 (magic packet) |

**Prerequisites:** Target computer must have WOL enabled in BIOS/UEFI and network adapter settings.

### Actions (7)
- **startPing** -- begin continuous ping monitoring of the target host
- **stopPing** -- stop ping monitoring
- **performARP** -- perform an ARP request to discover MAC address on local network
- **sendWOL** -- send a Wake-on-LAN magic packet to the configured MAC address
- **disableWOL** -- disable automatic WOL when host is detected as offline
- **enableWOL** -- enable automatic WOL when host is detected as offline
- **shutdownWindowsPC** -- send a remote shutdown command to a Windows PC (requires credentials)

### Feedbacks (1)
- **aliveState** -- true when the host responds to ping; false when unreachable. Use for connection status indicators.

### Variables (16)
| Variable | Description |
|----------|-------------|
| `$(pingwol:alive)` | Host alive state (true/false) |
| `$(pingwol:latency)` | Current ping latency (ms) |
| `$(pingwol:latency_avg)` | Average ping latency (ms) |
| `$(pingwol:latency_min)` | Minimum ping latency (ms) |
| `$(pingwol:latency_max)` | Maximum ping latency (ms) |
| `$(pingwol:packets_sent)` | Total packets sent |
| `$(pingwol:packets_received)` | Total packets received |
| `$(pingwol:packets_lost)` | Total packets lost |
| `$(pingwol:packet_loss_pct)` | Packet loss percentage |
| `$(pingwol:host)` | Configured host IP |
| `$(pingwol:mac)` | Configured MAC address |
| `$(pingwol:wol_enabled)` | WOL auto-send enabled (true/false) |
| `$(pingwol:last_seen)` | Timestamp of last successful ping |
| `$(pingwol:uptime)` | Time since host came online |
| `$(pingwol:ping_active)` | Whether ping monitoring is active |
| `$(pingwol:hostname)` | Resolved hostname of target |

### Button Patterns
```yaml
# Ping monitoring with response time display
- type: button
  text: "PC\n$(pingwol:latency) ms"
  color: "#CC0000"
  actions:
    down:
      - action: pingwol:sendWOL
    long_press:
      - action: pingwol:shutdownWindowsPC
  feedbacks:
    - type: pingwol:aliveState
      style:
        bgcolor: "#00CC00"
        text: "PC Online\n$(pingwol:latency) ms"

# WOL with alive check -- multi-step
- type: button
  text: "Wake PC"
  color: "#666666"
  steps:
    - # Step 1: PC is off -- press to wake
      style:
        text: "Wake PC\nOffline"
        bgcolor: "#CC0000"
      actions:
        down:
          - action: pingwol:sendWOL
          - action: pingwol:startPing
      feedbacks:
        - type: pingwol:aliveState
          style:
            bgcolor: "#00CC00"
            text: "PC Online\n$(pingwol:latency) ms"

    - # Step 2: PC is on -- press to shut down with confirmation
      style:
        text: "Shutdown?\nConfirm"
        bgcolor: "#CCCC00"
      actions:
        down:
          - action: pingwol:shutdownWindowsPC
          - action: companion:step_set
            options: { step: 1 }

# Network status dashboard button
- type: button
  text: "$(pingwol:host)\n$(pingwol:latency_avg) ms avg"
  color: "#333333"
  actions:
    down:
      - action: pingwol:startPing
    long_press:
      - action: pingwol:stopPing
  feedbacks:
    - type: pingwol:aliveState
      style:
        bgcolor: "#003300"
        text: "$(pingwol:host)\n$(pingwol:latency) ms\nLoss: $(pingwol:packet_loss_pct)%"
```

---

## SSH Remote Control (`generic-ssh`)

Execute shell commands on remote machines. Use for graceful shutdown, app launching, status checks.

### Connection
| Setting | Value |
|---------|-------|
| Host | Target IP |
| Port | 22 |
| Username/Password | SSH credentials |

### Actions (2)
- **execCommand** -- execute a command on the remote host. Supports multi-line commands (each line executed sequentially). Output is captured and can be stored in a variable.
- **shellCommand** -- execute a shell command using a full shell interpreter (supports pipes, redirects, and shell builtins)

### Feedbacks (1)
- **commandErrorState** -- true when the last command returned a non-zero exit code. Use for error indicators.

### Variables (1)
| Variable | Description |
|----------|-------------|
| `$(ssh:commandOutput)` | Output (stdout) of the last executed command |

### Button Patterns
```yaml
# Graceful shutdown button
- type: button
  text: "Shutdown"
  color: "#CC0000"
  actions:
    down:
      - action: ssh:send_command
        options:
          command: "sudo shutdown -h now"

# SSH multi-command sequence -- start streaming pipeline
- type: button
  text: "Start\nPipeline"
  color: "#0066CC"
  actions:
    down:
      - action: ssh:execCommand
        options:
          command: |
            cd /opt/streaming
            docker compose up -d
            sleep 5
            curl -s http://localhost:8080/health
      - action: companion:wait
        options: { time: 10000 }
      - action: ssh:execCommand
        options:
          command: "systemctl status streaming-pipeline --no-pager"
  feedbacks:
    - type: ssh:commandErrorState
      style:
        bgcolor: "#CC0000"
        text: "ERROR\nCheck logs"

# Remote status check with output display
- type: button
  text: "Status"
  color: "#333333"
  actions:
    down:
      - action: ssh:shellCommand
        options:
          command: "uptime | awk '{print $3,$4}' | sed 's/,//'"
  feedbacks:
    - type: ssh:commandErrorState
      style:
        bgcolor: "#CC0000"
        text: "SSH Error"
```

---

## HTTP Requests (`generic-http`)

Send arbitrary HTTP requests. Useful for APIs without dedicated Companion modules.

---

## TCP/UDP (`generic-tcp-udp`)

Send raw TCP or UDP commands. Used for:
- RS-232 over TCP (projector control via serial-to-IP adapter)
- Custom protocol devices
- Simple command-response devices

---

## Companion Internal (`companion-module-internal`)

The built-in Companion module provides control over Companion itself -- page navigation, button manipulation, variables, timers, triggers, delays, and macros. No external connection needed.

### Actions (50+)

#### Page Navigation
- **Page Set** -- go to a specific page by number
- **Page Up** -- go to next page
- **Page Down** -- go to previous page
- **Page Set (by variable)** -- go to page specified by a variable value

#### Button Control
- **Button Press** -- programmatically press another button (by page/row/col)
- **Button Release** -- programmatically release another button
- **Button Step Set** -- set another button's current step
- **Button Step Next** -- advance another button to next step
- **Button Style Text** -- change another button's text dynamically
- **Button Style Color** -- change another button's background color
- **Button Style PNG** -- change another button's image

#### Variables
- **Variable Set** -- set a custom variable to a value
- **Variable Math** -- perform math on a variable (add, subtract, multiply, divide)
- **Variable Increment** -- increment a variable by 1
- **Variable Decrement** -- decrement a variable by 1
- **Variable Set Expression** -- set variable using a math expression with other variables
- **Variable Store Timestamp** -- store current timestamp in a variable

#### Timers
- **Timer Start** -- start a named timer (countdown or countup)
- **Timer Stop** -- stop a running timer
- **Timer Toggle** -- toggle timer running state
- **Timer Reset** -- reset timer to initial value
- **Timer Set Duration** -- set/change timer duration
- **Timer Set Current** -- set timer to a specific current value
- **Timer Add Time** -- add time to a running timer
- **Timer Subtract Time** -- subtract time from a running timer

#### Triggers
- **Trigger on Variable Change** -- fire actions when a variable value changes
- **Trigger on Interval** -- fire actions on a repeating interval
- **Trigger on Startup** -- fire actions when Companion starts
- **Trigger on Time** -- fire actions at a specific time of day
- **Trigger Enable/Disable** -- enable or disable a trigger

#### Delays and Wait
- **Wait** -- pause action execution for specified milliseconds
- **Wait Until Variable** -- pause until a variable reaches a specific value

#### Macros / Action Sets
- **Run Action Set** -- execute a named group of actions
- **Enable/Disable Action Set** -- toggle action sets on/off

#### Surface Control
- **Surface Set Brightness** -- set Stream Deck brightness
- **Surface Lock** -- lock/unlock a surface (prevent accidental presses)
- **Surface Rescan** -- rescan for connected surfaces

### Feedbacks (15+)
- **Page Current** -- true when the current page matches
- **Button Step** -- true when a button is on a specific step
- **Variable Value** -- true when a variable matches a value
- **Variable Comparison** -- true when variable comparison is met (>, <, ==, !=)
- **Timer Running** -- true when a named timer is running
- **Timer Under Threshold** -- true when timer remaining is below a threshold
- **Timer Expired** -- true when a timer has finished
- **Timer Paused** -- true when a timer is paused
- **Trigger Enabled** -- true when a trigger is enabled
- **Surface Locked** -- true when a surface is locked
- **Connection Count** -- true when a specific number of surfaces are connected
- **Expression Result** -- true when a math expression evaluates to true
- **Custom Variable Exists** -- true when a named custom variable exists
- **Time of Day** -- true during specified time ranges
- **Instance Connected** -- true when a module instance is connected

### Variables (20+)
| Variable | Description |
|----------|-------------|
| `$(companion:page)` | Current page number |
| `$(companion:page_name)` | Current page name |
| `$(companion:time_hms)` | Current time (HH:MM:SS) |
| `$(companion:time_hm)` | Current time (HH:MM) |
| `$(companion:date)` | Current date (YYYY-MM-DD) |
| `$(companion:date_y)` | Current year |
| `$(companion:date_m)` | Current month |
| `$(companion:date_d)` | Current day |
| `$(companion:day_of_week)` | Day of the week name |
| `$(companion:uptime)` | Companion uptime |
| `$(companion:instance_count)` | Number of configured instances |
| `$(companion:connected_count)` | Number of connected instances |
| `$(companion:surface_count)` | Number of connected surfaces |
| `$(companion:timer_N_remaining)` | Timer N remaining time (formatted) |
| `$(companion:timer_N_elapsed)` | Timer N elapsed time (formatted) |
| `$(companion:timer_N_duration)` | Timer N configured duration |
| `$(companion:timer_N_state)` | Timer N state (running/stopped/expired) |
| `$(companion:custom_VARNAME)` | Custom variable value |
| `$(companion:build)` | Companion build number |
| `$(companion:version)` | Companion version |

### Button Patterns
```yaml
# Companion timer with threshold feedbacks -- sermon countdown
- type: button
  text: "Sermon\n$(companion:timer_sermon_remaining)"
  color: "#333333"
  actions:
    down:
      - action: companion:timer_toggle
        options:
          timer: "sermon"
    long_press:
      - action: companion:timer_reset
        options:
          timer: "sermon"
    double_press:
      - action: companion:timer_add_time
        options:
          timer: "sermon"
          time: 60000  # Add 1 minute
  feedbacks:
    - type: companion:timer_running
      options:
        timer: "sermon"
      style:
        bgcolor: "#00CC00"
        text: "$(companion:timer_sermon_remaining)"
    - type: companion:timer_under_threshold
      options:
        timer: "sermon"
        threshold: 120  # 2 minutes warning
      style:
        bgcolor: "#CCCC00"
        text: "$(companion:timer_sermon_remaining)\nWARNING"
    - type: companion:timer_under_threshold
      options:
        timer: "sermon"
        threshold: 30  # 30 seconds critical
      style:
        bgcolor: "#CC0000"
        text: "$(companion:timer_sermon_remaining)\nWRAP UP"
    - type: companion:timer_expired
      options:
        timer: "sermon"
      style:
        bgcolor: "#FF0000"
        text: "TIME!\nOVER"

# Page navigation with current page display
- type: button
  text: "Cameras\nPage 2"
  color: "#0066CC"
  actions:
    down:
      - action: companion:page_set
        options:
          page: 2
  feedbacks:
    - type: companion:page_current
      options:
        page: 2
      style:
        bgcolor: "#0066CC"
        text: "Cameras\n● Active"

# Variable counter with math operations
- type: button
  text: "Count\n$(companion:custom_tally_count)"
  color: "#333333"
  actions:
    down:
      - action: companion:variable_increment
        options:
          variable: "tally_count"
    long_press:
      - action: companion:variable_set
        options:
          variable: "tally_count"
          value: "0"
    rotate_cw:
      - action: companion:variable_math
        options:
          variable: "tally_count"
          operation: "add"
          value: 10
    rotate_ccw:
      - action: companion:variable_math
        options:
          variable: "tally_count"
          operation: "subtract"
          value: 10

# Surface brightness control
- type: button
  text: "Bright"
  color: "#333333"
  actions:
    rotate_cw:
      - action: companion:surface_set_brightness
        options:
          brightness: 100
    rotate_ccw:
      - action: companion:surface_set_brightness
        options:
          brightness: 30
    down:
      - action: companion:surface_set_brightness
        options:
          brightness: 70  # Default

# Startup trigger indicator with connection dashboard
- type: button
  text: "Systems\n$(companion:connected_count)/$(companion:instance_count)"
  color: "#333333"
  actions:
    down: []  # Read-only status
  feedbacks:
    - type: companion:variable_comparison
      options:
        variable: "connected_count"
        comparison: "=="
        value: "$(companion:instance_count)"
      style:
        bgcolor: "#00CC00"
        text: "ALL OK\n$(companion:connected_count) systems"

# Multi-action macro: "Start Service" sequence using action sets
- type: button
  text: "Start\nService"
  color: "#0066CC"
  actions:
    down:
      - action: companion:variable_set
        options:
          variable: "service_phase"
          value: "starting"
      - action: companion:button_press
        options:
          page: 3
          row: 0
          col: 0  # Triggers the WOL button
      - action: companion:wait
        options: { time: 30000 }
      - action: companion:button_press
        options:
          page: 2
          row: 0
          col: 0  # Triggers scene recall
      - action: companion:variable_set
        options:
          variable: "service_phase"
          value: "ready"
  feedbacks:
    - type: companion:variable_value
      options:
        variable: "service_phase"
        value: "starting"
      style:
        bgcolor: "#CCCC00"
        text: "Starting...\n$(companion:custom_service_phase)"
    - type: companion:variable_value
      options:
        variable: "service_phase"
        value: "ready"
      style:
        bgcolor: "#00CC00"
        text: "Ready\n● Service"
```

---

## Internal: Timer (`companion-timer`)

Built-in Companion timer module. No external connection needed. See the Companion Internal section above for full timer actions, feedbacks, and variables.

- **Start/Stop/Toggle Timer** -- countdown or countup
- **Set Timer Duration** -- configure time
- **Timer Feedback** -- shows remaining time on button, changes color at thresholds

## Internal: Variables (`companion-variables`)

Companion's built-in variable system. See the Companion Internal section above for full variable actions, feedbacks, and variables.

- **Set Variable** -- store a value
- **Variable Feedback** -- display variable value on button text
- **Math Operations** -- increment/decrement variables
