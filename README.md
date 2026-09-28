# davidjm.cliamp

Cliamp in the bar. A [cliamp](https://github.com/) terminal music player
widget + service for the Omarchy shell: a compact now-playing pill, full
transport controls, your **favourites** list, seek, volume, and the
repeat/shuffle/mono modes — all driven over cliamp's headless IPC daemon and
its favourites store.

## What you get

| Piece | File | Kind |
|---|---|---|
| IPC engine (owns the cliamp event stream + bounded favourites watch) | `Service.qml` | `service` |
| Bar pill + keyboard panel | `BarWidget.qml` | `bar-widget` |
| Bounded process bridge / pidfd identity guard | `bounded_process.py`, `process_guard.py` | — |
| No-follow favourites reader | `favorites_reader.py` | — |
| Pure parsing/format helpers | `Model.js` | — |

The widget is **always visible** (even when the daemon is down, it shows a
"not running" banner with a one-click *Start daemon* button), so it doubles
as a cliamp launcher. Favourites are read with a bounded, no-shell, no-follow
file reader, so anything you favourite in the cliamp TUI appears in the widget
within a moment.

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

2. Make sure the widget is in a bar section of `~/.config/omarchy/shell.json`,
   e.g.:

   ```jsonc
   {
     "bar": {
       "layout": { "right": [
         "omarchy.tray",
         { "id": "davidjm.cliamp" }
       ] }
     }
   }
   ```

   The bar layout entry is enough. The shell treats a plugin as enabled when
   its id appears *anywhere* in `shell.json` — `PluginRegistry.findEntryLocation`
   checks `bar.layout` before `plugins[]` — so placing the widget in the bar
   enables the **service** too, and the widget finds it via
   `bar.shell.serviceFor("davidjm.cliamp")`. A separate `plugins[]` entry is
   only needed for a service with no bar widget of its own.

   Check it took effect with `omarchy plugin list`: `davidjm.cliamp` should read
   `enabled`.

   Note that `keepLoaded` is set, so the service instance survives plugin
   hot-reload. **Edits to `Service.qml` therefore need a shell restart to take
   effect** (`omarchy restart shell`); edits to the Python helpers do not, since
   each IPC call spawns a fresh interpreter.
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
runtime.playlist` process through `bounded_process.py`. The bridge reads fixed
chunks, caps each newline-delimited record before QML sees it, and terminates a
child that exceeds the cap. A bounded state probe provides a connection
watchdog when playback is idle. Daemon start/stop uses a pidfd-backed identity
check (`process_guard.py`) rather than a broad process match or a bare PID
signal. The last validated snapshot is retained across transient disconnects,
and playback/settings commands use a bounded, duplicate-suppressing queue.
Favourites are read by `favorites_reader.py` with no-follow, nonblocking,
ownership, type, link-count, size, and descriptor-stability checks. When the
daemon disappears the service backs off exponentially (settings `reconnectMs`
→ `reconnectCapMs`) and marks itself offline.

Quirks worked around:

- cliamp expects one JSON object per line on the event stream; the bridge
  bounds a final unterminated line before flushing it.
- Favourites toggled in the TUI while the widget is open show up at the next
  poll tick (default 2.5 s).
- `omarchy-launch-terminal` needs the desktop session (`WAYLAND_DISPLAY`,
  `HYPRLAND_INSTANCE_SIGNATURE`, `OMARCHY_PATH`) to reach the compositor, so
  the *Open cliamp* button's child gets those on top of the scrubbed IPC
  environment. Without them `uwsm-app` fails with "no compositor running" and
  no window appears. `WAYLAND_DISPLAY` is recovered from the newest `wayland-*`
  socket in `XDG_RUNTIME_DIR` when unset. The `cliamp` child itself stays on
  the tight scrub.

## Troubleshooting

Child stderr is forwarded by the bridge and logged as
`cliamp <source>: <message>` (sources: `stream`, `health`, `command`, `guard`,
`daemon`, `favorites`), so cliamp's own explanations reach the shell log
instead of `/dev/null`. Repeats are folded per source and the whole session is
capped, because the health probe re-runs every few seconds.

```
grep cliamp "$(ls -t /run/user/$UID/quickshell/by-id/*/log.log | head -1)"
```

Remember the `keepLoaded` caveat above: after editing `Service.qml`, restart the
shell before concluding that a logging or behaviour change did not work.

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