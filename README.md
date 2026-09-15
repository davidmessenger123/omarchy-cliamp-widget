# davidjm.cliamp

Cliamp in the bar. A [cliamp](https://github.com/) terminal music player
widget + service for the Omarchy shell: a compact now-playing pill, full
transport controls, your **favourites** list, seek, volume, and the
repeat/shuffle/mono modes — all driven over cliamp's headless IPC daemon and
its favourites store.

## What you get

| Piece | File | Kind |
|---|---|---|
| IPC engine (owns the cliamp event stream + favourites poll) | `Service.qml` | `service` |
| Bar pill + keyboard panel | `BarWidget.qml` | `bar-widget` |
| Pure parsing/format helpers | `Model.js` | — |

The widget is **always visible** (even when the daemon is down, it shows a
"not running" banner with a one-click *Start daemon* button), so it doubles
as a cliamp launcher. Favourites are read straight from
`~/.config/cliamp/favorites.toml`, so anything you favourite in the cliamp
TUI appears in the widget within a moment.

## Requirements

- `cliamp` ≥ 2.0 on `PATH` (the daemon it talks to lives at
  `~/.config/cliamp/cliamp.sock`).
- The default `omarchy-launch-terminal` helper for the *Open cliamp* button
  (opens a terminal running the real TUI).

Set `binary` in the widget settings to point at a non-default cliamp binary.

## Install / enable

1. Clone this repo where Omarchy can see it as a plugin:

   ```sh
   git clone https://github.com/davidmessenger123/omarchy-cliamp-widget \
     ~/.config/omarchy/plugins/davidjm.cliamp
   ```

2. Make sure the plugin is enabled and the widget is in a bar section of
   `~/.config/omarchy/shell.json`, e.g.:

   ```jsonc
   {
     "bar": {
       "sections": { "right": [
         "omarchy.tray",
         { "id": "davidjm.cliamp" }
       ] }
     },
     "plugins": [
       { "id": "davidjm.cliamp", "enabled": true }
     ]
   }
   ```

   The `plugins` entry is what registers the **service**; the bar layout entry
   places the **widget**. Both are required for the widget to see playback
   state (it finds the service via `bar.shell.serviceFor("davidjm.cliamp")`).
3. Start the cliamp daemon (once, headless — the panel button does this too):

   ```sh
   cliamp --daemon --log-level error
   ```

   Or register it with your session so it survives logout, e.g. a systemd user
   unit:

   ```ini
   # ~/.config/systemd/user/cliamp.service
   [Unit]
   Description=Cliamp daemon
   [Service]
   ExecStart=/usr/bin/cliamp --daemon --log-level error
   Restart=on-failure
   [Install]
   WantedBy=default.target
   ```

## Usage

### The pill

- **Left click** — play/pause (starts the daemon when it's down).
- **Right click** — toggle the control panel.
- **Middle click** — stop.
- **Scroll up/down** — previous / next track.
- The music glyph lights up accent-coloured while audio is actually flowing.

### The panel

- Now-playing header (title / artist / album · mode chips).
- Seek slider for tracks; an animated band visualizer stands in for the
  progress bar on non-seekable live streams.
- Transport row: previous / play-pause / stop / next, plus shuffle, repeat
  (cycles Off → All → 1 → Off) and mono toggles.
- Volume slider in cliamp's native dB range (−30 … +6); right-click jams it
  to −30 dB (mute).
- **Favourites**: everything you've favourited in cliamp. Click a row to play
  it (`url.load` with `play: true`). The currently-playing favourite is
  highlighted. Refresh button on the right; the list also updates on daemon
  (re)connect and every `favPollMs`.
- Footer: EQ preset + playback speed readout, favourite count, *Stop daemon*
  and *Open cliamp* buttons.

## How the plumbing works

`Service.qml` runs one persistent `cliamp remote events runtime.state
runtime.playlist` process. cliamp pushes a full snapshot as the first (retained)
event, then fires deltas whenever state changes — but deliberately **not** on
position ticks, so the service advances `displayPosition` itself on a 1 s timer
while `state == playing`. Favourites are not exposed over IPC, so they're read
directly from `~/.config/cliamp/favorites.toml` (a tiny TOML list of `[[entry]]`
blocks) on a low-frequency poll plus on connect. When the daemon disappears the
service backs off exponentially (settings `reconnectMs` → `reconnectCapMs`) and
marks itself offline.

Quirks worked around:

- `StdioCollector` with `waitForEnd: false` **accumulates** output into `text`;
  the service consumes only the newly appended bytes (a `consumed` offset) and
  splits on newlines.
- cliamp expects one JSON object per line on the event stream.
- Favourites toggled in the TUI while the widget is open show up at the next
  poll tick (default 2.5 s).

## Settings

tunable per bar layout entry in `shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `binary` | `"cliamp"` | cliamp binary path |
| `favPollMs` | `2500` | favourites store poll interval (`500`–`30000`) |
| `reconnectMs` | `2000` | initial reconnect delay after the daemon dies |
| `reconnectCapMs` | `30000` | reconnect backoff ceiling |

## Layout notes

- Horizontal bar: glyph only.
- Vertical bar: glyph only.