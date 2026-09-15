import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Cliamp IPC engine.
//
// This plugin is both a `service` and a `bar-widget`. The bar renders one
// widget per monitor, but a single Service instance (enabled via the `plugins`
// array in shell.json) owns every connection to the cliamp daemon:
//
//   * a persistent `cliamp remote events runtime.state runtime.playlist`
//     process that pushes newline-delimited JSON snapshots as they happen;
//   * a healthy-poll of the favourites store (~/.config/cliamp/favorites.toml),
//     re-read whenever cliamp reconnects and on a slow cadence afterwards;
//   * a 1s tick timer that advances a local display position between events,
//     because cliamp deliberately does not emit events for playback ticks.
//
// Bar widgets reach this object through their scoped shell API:
//   bar.shell.serviceFor("davidjm.cliamp")
Item {
  id: root

  // ------------------------------------------------------------------- state
  // Shared, reactive state the bar widgets bind against.

  property var snapshot: Model.blankSnapshot()
  property real displayPosition: 0
  property bool connected: false
  property bool connecting: true
  property string lastError: ""
  property int failCount: 0

  property var favorites: []
  property string favoritesSource: ""

  // Widget-provided settings (merged with manifest defaults upstream).
  property var settings: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string cliampPath: String(setting("binary", "cliamp") || "cliamp")
  readonly property string cliampSocket: root.home + "/.config/cliamp/cliamp.sock"
  property string home: Quickshell.env("HOME") || ""

  // Apply the widget's effective settings (called on construction and on
  // every shell.json edit). Cheap: only the reconnect cadence and favourites
  // poll rate can be tuned at runtime.
  function applySettings(s) {
    root.settings = s || {}
    var want = Model.clampInt(root.setting("reconnectMs", 2000), 250, 30000, 2000)
    var cap = Model.clampInt(root.setting("reconnectCapMs", 30000), 1000, 60000, 30000)
    root.reconnectBase = want
    root.reconnectCap = cap
    reconnectTimer.interval = Math.min(300, want)
    favoritesTimer.interval = Model.clampInt(root.setting("favPollMs", 2500), 500, 30000, 2500)
    if (!root.connected && root.connecting) reconnectTimer.restart()
  }

  // ------------------------------------------------------------------ stream

  // One persistent process; cliamp re-subscribes to its own retained events,
  // so the moment the socket is up we receive the current snapshot followed
  // by deltas. Exit (daemon stopped, socket missing) schedules a reconnect.
  Process {
    id: stream
    command: []
    stdout: StdioCollector {
      id: streamOut
      waitForEnd: false
      onDataChanged: root.onStreamProgress()
    }
    stderr: StdioCollector {
      id: streamErr
      waitForEnd: false
    }
    onExited: root.onStreamExited(exitCode)
  }

  property int streamSession: 0
  property int consumed: 0

  function startStream() {
    root.streamSession++
    root.consumed = 0
    root.streamBuffer = ""
    stream.command = root.cliampCommand(["remote", "events",
      "runtime.state", "runtime.playlist"])
    root.connecting = true
    stream.running = true
  }

  // StdioCollector accumulates all output into `text` (waitForEnd false means
  // it grows live). Consume only the newly-appended bytes and split on
  // newlines; cliamp's remote-event output is one compact JSON object per line.
  property string streamBuffer: ""

  function onStreamProgress() {
    var full = String(streamOut.text || "")
    var extra = full.length > root.consumed ? full.slice(root.consumed) : ""
    root.consumed = full.length
    root.streamBuffer = root.streamBuffer + extra
    while (true) {
      var nl = root.streamBuffer.indexOf("\n")
      if (nl < 0) break
      var line = root.streamBuffer.slice(0, nl)
      root.streamBuffer = root.streamBuffer.slice(nl + 1)
      root.ingestLine(line)
    }
  }

  function ingestLine(line) {
    var snap = Model.parseEventLine(line)
    if (!snap) return
    root.online(snap)
  }

  function onStreamExited(exitCode) {
    root.offline("cliamp exited (code " + exitCode + ")")
  }

  Timer {
    id: reconnectTimer
    interval: 500
    repeat: false
    onTriggered: root.startStream()
  }

  property int reconnectBase: 2000
  property int reconnectCap: 30000
  property int reconnectTry: 0

  function scheduleReconnect() {
    root.reconnectTry++
    var backoff = Math.min(root.reconnectCap,
      root.reconnectBase * Math.pow(2, Math.min(root.reconnectTry, 5) - 1))
    reconnectTimer.interval = backoff
    reconnectTimer.restart()
  }

  // -- lifecycle of the shared snapshot -------------------------------

  function online(snap) {
    var wasConnected = root.connected
    root.snapshot = snap
    root.displayPosition = snap.position
    root.connected = true
    root.connecting = false
    root.failCount = 0
    root.lastError = ""
    if (!wasConnected) root.reconnectTry = 0
    // Favourites may have changed while we were away; refresh once on the
    // connect transition (the poll timer keeps them current afterwards).
    if (!wasConnected) root.refreshFavorites()
  }

  function offline(reason) {
    root.connected = false
    root.connecting = false
    root.lastError = String(reason || "cliamp is not running")
    root.failCount++
    root.snapshot = Model.blankSnapshot()
    root.displayPosition = 0
    root.scheduleReconnect()
  }

  // ------------------------------------------------------------- favourites

  // cliamp stores favourites in a small TOML file and exposes no IPC query
  // for them, so we read the store directly. It is tiny; a low-frequency poll
  // plus an explicit refresh from the panel's button is plenty.
  Process {
    id: favProc
    command: []
    stdout: StdioCollector {
      id: favOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: favErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.favBusy = false
      if (exitCode !== 0) return
      var text = String(favOut.text || "")
      if (text === root.favoritesSource) return
      root.favoritesSource = text
      root.favorites = Model.parseFavoritesToml(text)
    }
  }

  property bool favBusy: false

  function refreshFavorites() {
    if (root.favBusy) return
    root.favBusy = true
    favProc.command = ["/bin/sh", "-c",
      "cat \"" + root.home + "/.config/cliamp/favorites.toml\""]
    favProc.running = true
  }

  Timer {
    id: favoritesTimer
    interval: 2500
    repeat: true
    running: true
    onTriggered: { if (root.connected) root.refreshFavorites() }
  }

  // ------------------------------------------------------------------ utils

  function cliampCommand(args) {
    var all = [root.cliampPath]
    return all.concat(args || [])
  }

  // Fire-and-forget playback command. Commands are short and go straight to
  // the unix socket; no shell is involved.
  function run(args) {
    Quickshell.execDetached(root.cliampCommand(args))
  }

  // ------------------------------------------------------------------ timer

  // Advance the displayed position every second while playing. Events carry
  // exact positions but never arrive for playback ticks, so this keeps the
  // pill and seek bar smooth without spamming the daemon.
  Timer {
    id: tickTimer
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      if (!root.connected) return
      var snap = root.snapshot
      if (Model.playing(snap)) {
        var next = root.displayPosition + snap.speed
        if (Model.isStream(snap) || !snap.seekable || snap.duration <= 0) {
          root.displayPosition = next
        } else if (next < snap.duration) {
          root.displayPosition = next
        } else if (snap.repeat === "One") {
          root.displayPosition = 0
        } else {
          // Rolled past the end; next event will correct the position.
          root.displayPosition = snap.duration
        }
      }
    }
  }

  // Timers touching the position only make sense while anything is playing;
  // the same connect path that arms the stream also re-onlines position.
  Component.onCompleted: {
    root.reconnectTry = 0
    root.startStream()
  }
}