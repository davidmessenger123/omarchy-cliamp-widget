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
//   * a healthy read of the favourites store (~/.config/cliamp/favorites.toml)
//     through the no-follow reader;
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
  property var lastGoodSnapshot: Model.blankSnapshot()
  property bool lastGoodValid: false
  property real displayPosition: 0
  property bool connected: false
  property bool connecting: true
  property string lastError: ""
  property int failCount: 0

  property var favorites: []
  property string favoritesSource: ""

  // --------------------------------------------------------------- queue
  // Live playlist (cliamp's queue.* operations). The list is capped to one
  // page so the panel never instantiates an unbounded Repeater.
  property var queueTracks: []
  property int queueTotal: 0
  property int queueIndex: -1
  property bool queueLoading: false
  property bool queueMutating: false
  property int queueRevision: 0
  property string queueError: ""
  property bool queueVisible: false
  property int queueSession: 0
  property int queueMutationRevision: 0
  property bool queueRefreshPending: false
  readonly property int queuePageSize: Model.MAX_QUEUE_ROWS
  readonly property int queueMaxOutput: 1024 * 1024

  property var settings: ({})
  property var pendingSettings: ({})
  property bool settingsFlushPending: false
  property int settingsRevision: 0

  property var commandQueue: []
  property real sleepUntil: 0
  property int sleepRemaining: 0
  readonly property bool sleepActive: root.sleepRemaining > 0
  property bool commandRunning: false
  property string currentCommandKey: ""
  property int commandGeneration: 0
  property bool commandCollect: false
  property string commandOutput: ""
  property bool commandOverflow: false
  property int commandMaxOutput: 65536
  property var currentCommandCallback: null
  readonly property int maxCommandQueue: 32

  // Child stderr is where cliamp explains itself ("cliamp is not running",
  // wayland failures, bad IPC replies), and discarding it is how a broken
  // bridge can look identical to a widget with nothing to say. Repeats are
  // folded because the health probe re-runs every few seconds.
  property var stderrLast: ({})
  property int stderrLogged: 0
  readonly property int maxStderrLines: 200
  readonly property int maxStderrLength: 200

  function logStderr(source, line) {
    var text = String(line === undefined || line === null ? "" : line).trim()
    if (!text || text.length > 4096) return
    if (text.length > root.maxStderrLength) text = text.slice(0, root.maxStderrLength) + "..."
    if (root.stderrLogged >= root.maxStderrLines) return
    var seen = {}
    for (var key in root.stderrLast) seen[key] = root.stderrLast[key]
    if (seen[source] === text) return
    seen[source] = text
    root.stderrLast = seen
    root.stderrLogged++
    console.warn("cliamp " + source + ": " + text)
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  property string home: Quickshell.env("HOME") || ""
  readonly property string bridgePath: Model.scriptPath(Qt.resolvedUrl("bounded_process.py"))
  readonly property string guardPath: Model.scriptPath(Qt.resolvedUrl("process_guard.py"))
  readonly property string favoritesReaderPath: Model.scriptPath(Qt.resolvedUrl("favorites_reader.py"))
  readonly property string interpreterPath: "/usr/bin/python3"

  function flushSettings() {
    root.settingsFlushPending = false
    if (root.settingsRevision <= 0) return
    root.settings = root.pendingSettings
    root.pendingSettings = ({})
    var want = Model.clampInt(root.setting("reconnectMs", 2000), 250, 30000, 2000)
    var cap = Model.clampInt(root.setting("reconnectCapMs", 30000), 1000, 60000, 30000)
    root.reconnectBase = want
    root.reconnectCap = cap
    reconnectTimer.interval = Math.min(300, want)
    favoritesTimer.interval = Model.clampInt(root.setting("favPollMs", 2500), 500, 30000, 2500)
    if (!root.connected && root.connecting) reconnectTimer.restart()
  }

  function applySettings(s) {
    root.pendingSettings = Model.boundedSettings(s)
    root.settingsRevision++
    if (root.settingsFlushPending) return
    root.settingsFlushPending = true
    Qt.callLater(root.flushSettings)
  }

  // ------------------------------------------------------------------ stream

  property int streamSession: 0
  property int streamStopSession: -1
  property int streamIgnoreSession: -1
  property int lastEventSeq: -1
  property int lastEventRevision: -1
  property int healthSession: 0
  property int healthFailures: 0
  property int daemonPid: 0
  property bool daemonStarting: false
  property bool favoritesLoading: false
  property int favoritesSession: 0
  property int guardSession: 0
  property int daemonSession: 0

  readonly property string cliampPath: Model.safeExecutable(setting("binary", "cliamp")) || "cliamp"
  readonly property string cliampDir: Model.safeFavoritesPath(home) === ""
    ? "" : home + "/.config/cliamp"
  readonly property string cliampSocket: root.cliampDir === ""
    ? "" : root.cliampDir + "/cliamp.sock"

  function startStream() {
    if (stream.running) return
    var command = root.cliampCommand(["remote", "events", "runtime.state", "runtime.playlist"])
    if (command.length === 0 || root.bridgePath === "" || root.interpreterPath === "") {
      root.offline("cliamp executable is invalid")
      return
    }
    root.streamSession++
    root.streamStopSession = -1
    root.streamIgnoreSession = -1
    root.lastEventSeq = -1
    root.lastEventRevision = -1
    streamOut.generation = root.streamSession
    stream.command = [root.interpreterPath, "-I", root.bridgePath, "stream",
      "--max-line", String(Model.MAX_EVENT_LINE), "--"].concat(command)
    root.connecting = true
    stream.running = true
  }

  function ingestLine(line, generation) {
    if (generation !== root.streamSession) return
    var event = Model.parseEvent(line)
    if (!event) return
    if (event.seq >= 0 && root.lastEventSeq >= 0 && event.seq < root.lastEventSeq) return
    if (!root.online(event.snapshot, generation)) return
    if (event.seq >= 0) root.lastEventSeq = event.seq
  }

  function onStreamExited(exitCode) {
    if (root.streamIgnoreSession === root.streamSession) {
      root.streamIgnoreSession = -1
      return
    }
    if (root.streamStopSession === root.streamSession) {
      root.streamStopSession = -1
      streamRestartTimer.restart()
      return
    }
    root.offline("cliamp exited (code " + exitCode + ")")
  }

  Process {
    id: stream
    command: []
    stdout: SplitParser {
      id: streamOut
      property int generation: -1
      onRead: function(line) {
        root.ingestLine(String(line || "").trim(), streamOut.generation)
      }
    }
    stderr: SplitParser {
      onRead: function(line) { root.logStderr("stream", line) }
    }
    onExited: function(exitCode) { root.onStreamExited(exitCode) }
  }

  Process {
    id: healthProc
    property int generation: -1
    property int streamSession: -1
    property int daemonSession: -1
    property string output: ""
    property bool overflow: false
    property bool timedOut: false
    command: []
    stdout: SplitParser {
      id: healthOut
      property int generation: -1
      onRead: function(data) {
        if (healthOut.generation !== healthProc.generation || healthProc.overflow) return
        var chunk = String(data || "")
        if (healthProc.output.length + chunk.length > 65536) {
          healthProc.overflow = true
          healthProc.output = ""
          healthProc.running = false
          return
        }
        healthProc.output += chunk + "\n"
      }
    }
    stderr: SplitParser {
      onRead: function(line) { root.logStderr("health", line) }
    }
    onExited: function(exitCode) {
      var generation = healthProc.generation
      var streamSession = healthProc.streamSession
      var daemonSession = healthProc.daemonSession
      if (generation !== root.healthSession ||
          streamSession !== root.streamSession ||
          daemonSession !== root.daemonSession) return
      healthTimeout.stop()
      var body = String(healthProc.output || "")
      var valid = false
      if (exitCode === 0 && !healthProc.overflow && !healthProc.timedOut) {
        try {
          var envelope = JSON.parse(body)
          if (!envelope || envelope.ok !== true || envelope.version !== 2 || envelope.id !== "cliamp")
            throw new Error("invalid cliamp state")
          var raw = envelope.snapshot || envelope.data
          var snap = Model.snapshotFrom(raw)
          if (snap) {
            valid = true
            root.healthFailures = 0
            root.online(snap, streamSession)
            if (!stream.running) Qt.callLater(function() { root.startStream() })
          }
        } catch (e) {
          valid = false
        }
      }
      healthProc.output = ""
      healthProc.overflow = false
      healthProc.timedOut = false
      if (valid) return
      root.healthFailures++
      if (root.connected && root.healthFailures >= 2) {
        root.offline("cliamp health check failed")
      } else if (!root.connected) {
        root.scheduleReconnect()
      }
    }
  }

  Timer {
    id: healthTimeout
    interval: 5000
    repeat: false
    onTriggered: {
      if (!healthProc.running) return
      healthProc.timedOut = true
      healthProc.signal(15)
      healthProc.running = false
      healthProc.generation = -1
      healthSession++
      healthTimeout.stop()
      if (root.connected) root.offline("cliamp health check timed out")
      else root.scheduleReconnect()
    }
  }

  function startHealthProbe() {
    if (healthProc.running || (!root.connected && !root.connecting)) return
    var command = root.cliampCommand(["remote", "state"])
    if (command.length === 0 || root.bridgePath === "" || root.interpreterPath === "") return
    var streamSession = root.streamSession
    var daemonSession = root.daemonSession
    root.healthSession++
    healthProc.generation = root.healthSession
    healthProc.streamSession = streamSession
    healthProc.daemonSession = daemonSession
    healthOut.generation = root.healthSession
    healthProc.output = ""
    healthProc.overflow = false
    healthProc.timedOut = false
    healthProc.command = [root.interpreterPath, "-I", root.bridgePath, "run",
      "--max-output", "65536", "--timeout", "4", "--"].concat(command)
    healthProc.running = true
    healthTimeout.restart()
  }

  Timer {
    id: healthTimer
    interval: 5000
    repeat: true
    running: root.connected || root.connecting
    onTriggered: root.startHealthProbe()
  }

  Timer {
    id: streamRestartTimer
    interval: 100
    repeat: false
    onTriggered: {
      if (!stream.running) root.startStream()
    }
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

  function online(snap, sourceSession) {
    if (sourceSession !== root.streamSession) return false
    if (!Model.shouldApplySnapshot(snap, root.lastEventRevision, root.streamSession, sourceSession)) return false
    if (!snap.track) return false
    var wasConnected = root.connected
    var wasPlaylistRevision = root.snapshot.playlistRevision
    if (snap.revision >= 0) root.lastEventRevision = snap.revision
    root.lastGoodSnapshot = snap
    root.lastGoodValid = true
    root.snapshot = snap
    root.displayPosition = snap.position
    root.connected = true
    root.connecting = false
    root.failCount = 0
    root.healthFailures = 0
    root.lastError = ""
    root.daemonStarting = false
    daemonStartTimer.stop()
    if (!wasConnected) {
      root.reconnectTry = 0
      root.refreshFavorites()
      if (root.queueVisible) root.refreshQueue()
    } else if (root.queueVisible && snap.playlistRevision !== wasPlaylistRevision) {
      // External queue edits (TUI, MPRIS, another client) arrive as playlist
      // revision bumps. Defer while closed so a hidden panel never polls.
      root.refreshQueue()
    }
    return true
  }

  function offline(reason) {
    root.connected = false
    root.connecting = false
    root.lastError = String(reason || "cliamp is not running")
    root.failCount++
    root.displayPosition = root.lastGoodValid ? root.lastGoodSnapshot.position : 0
    root.healthSession++
    root.favoritesSession++
    root.favoritesLoading = false
    favoritesProc.running = false
    favoritesTimeout.stop()
    root.streamIgnoreSession = root.streamSession
    stream.running = false
    healthProc.running = false
    healthTimeout.stop()
    root.commandGeneration++
    commandTimeout.stop()
    commandProc.running = false
    root.commandQueue = []
    root.commandRunning = false
    root.currentCommandKey = ""
    root.currentCommandCallback = null
    root.commandCollect = false
    root.commandOutput = ""
    root.commandOverflow = false
    root.queueSession++
    root.queueLoading = false
    root.queueMutating = false
    root.queueRefreshPending = false
    root.queueTracks = []
    root.queueTotal = 0
    root.queueIndex = -1
    root.queueRevision++
    root.queueError = root.lastError
    root.scheduleReconnect()
  }

  function boundedRunCommand(args, maximum) {
    var command = root.cliampCommand(args)
    if (command.length === 0 || root.bridgePath === "" || root.interpreterPath === "") return []
    return [root.interpreterPath, "-I", root.bridgePath, "run",
      "--max-output", String(maximum), "--timeout", "8", "--"].concat(command)
  }

  function guardCommand(action) {
    if (root.guardPath === "" || root.interpreterPath === "" || root.cliampDir === "") return []
    return [root.interpreterPath, "-I", root.guardPath, action,
      root.cliampDir + "/cliamp.sock.pid", root.cliampPath]
  }

  function launchDaemon() {
    if (root.daemonStarting || daemonProc.running) return
    var command = root.boundedRunCommand(["--daemon", "--log-level", "error"], 65536)
    if (command.length === 0) {
      root.lastError = "cliamp executable is invalid"
      return
    }
    root.daemonStarting = true
    daemonProc.generation = ++root.daemonSession
    daemonProc.timedOut = false
    daemonProc.command = command
    daemonProc.running = true
    daemonStartTimer.restart()
  }

  function startDaemon() {
    if (root.daemonStarting || daemonProc.running || guardProc.running) return
    guardProc.action = "check"
    guardProc.generation = ++root.guardSession
    guardProc.command = root.guardCommand("check")
    if (guardProc.command.length === 0) {
      root.lastError = "cliamp daemon identity is unavailable"
      return
    }
    guardTimeout.restart()
    guardProc.running = true
  }

  function stopDaemon() {
    if (guardProc.running || daemonProc.running) return
    guardProc.action = "stop"
    guardProc.generation = ++root.guardSession
    guardProc.command = root.guardCommand("stop")
    if (guardProc.command.length === 0) {
      root.lastError = "cliamp daemon identity is unavailable"
      return
    }
    guardProc.timedOut = false
    guardTimeout.restart()
    guardProc.running = true
  }

  Process {
    id: guardProc
    property int generation: -1
    property string action: ""
    property bool timedOut: false
    command: []
    stdout: SplitParser {}
    stderr: SplitParser {
      onRead: function(line) { root.logStderr("guard", line) }
    }
    onExited: function(exitCode) {
      if (guardProc.generation !== root.guardSession) return
      guardTimeout.stop()
      if (guardProc.action === "check") {
        if (exitCode === 0 && !guardProc.timedOut) {
          root.daemonPid = 1
          root.daemonStarting = false
        } else {
          root.daemonPid = 0
          root.launchDaemon()
        }
        guardProc.timedOut = false
        return
      }
      if (exitCode === 0 && !guardProc.timedOut) {
        root.daemonPid = 0
        root.lastError = "cliamp daemon stopped"
      } else {
        root.lastError = "cliamp daemon identity check failed"
      }
      guardProc.timedOut = false
    }
  }

  Timer {
    id: guardTimeout
    interval: 5000
    repeat: false
    onTriggered: {
      if (!guardProc.running) return
      guardProc.timedOut = true
      guardProc.signal(15)
      guardProc.running = false
      guardProc.generation = -1
      root.daemonPid = 0
      root.daemonStarting = false
      root.lastError = "cliamp daemon identity check failed"
    }
  }

  Process {
    id: daemonProc
    property int generation: -1
    property bool timedOut: false
    command: []
    stdout: SplitParser {}
    stderr: SplitParser {
      onRead: function(line) { root.logStderr("daemon", line) }
    }
    onExited: function(exitCode) {
      if (daemonProc.generation !== root.daemonSession) return
      daemonStartTimer.stop()
      root.daemonStarting = false
      if (exitCode !== 0 || daemonProc.timedOut) {
        if (!root.connected) root.lastError = "cliamp daemon did not start"
      } else {
        root.daemonPid = 1
      }
    }
  }

  Timer {
    id: daemonStartTimer
    interval: 8000
    repeat: false
    onTriggered: {
      if (daemonProc.running) {
        daemonProc.timedOut = true
        daemonProc.signal(15)
        daemonProc.running = false
        daemonProc.generation = -1
        daemonSession++
      }
      root.daemonStarting = false
      if (!root.connected) root.lastError = "cliamp daemon did not start"
    }
  }

  // ------------------------------------------------------------- favourites

  // cliamp stores favourites in a small TOML file and exposes no IPC query
  // for them, so the no-follow reader performs each bounded reload.
  Process {
    id: favoritesProc
    property int generation: -1
    property bool timedOut: false
    property bool exited: false
    property int exitCode: -1
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var body = text
        var generation = favoritesProc.generation
        Qt.callLater(function() {
          if (favoritesProc.generation !== generation || generation !== root.favoritesSession) return
          if (!favoritesProc.exited || favoritesProc.exitCode !== 0 || favoritesProc.timedOut) return
          root.favoritesLoading = false
          favoritesTimeout.stop()
          root.ingestFavorites(body)
        })
      }
    }
    stderr: SplitParser {
      onRead: function(line) { root.logStderr("favorites", line) }
    }
    onExited: function(exitCode) {
      if (favoritesProc.generation !== root.favoritesSession) return
      favoritesTimeout.stop()
      favoritesProc.exited = true
      favoritesProc.exitCode = exitCode
      root.favoritesLoading = false
      favoritesProc.timedOut = false
    }
  }

  Timer {
    id: favoritesTimeout
    interval: 5000
    repeat: false
    onTriggered: {
      if (!favoritesProc.running) return
      favoritesProc.timedOut = true
      favoritesProc.signal(15)
      favoritesProc.running = false
      root.favoritesLoading = false
      root.favoritesSession++
    }
  }

  function ingestFavorites(value) {
    var body = String(value || "")
    if (body.length > Model.MAX_FAVORITES_BYTES) return false
    var parsed = Model.parseFavoritesToml(body)
    if (parsed === null) return false
    if (body === root.favoritesSource) return true
    root.favoritesSource = body
    root.favorites = parsed
    return true
  }

  function refreshFavorites() {
    if (!root.connected || root.favoritesLoading || root.favoritesReaderPath === "" || root.bridgePath === "" || root.interpreterPath === "") return
    var target = Model.safeFavoritesPath(root.home)
    if (target === "") return
    var command = [root.interpreterPath, "-I", root.favoritesReaderPath, root.home, target]
    root.favoritesLoading = true
    root.favoritesSession++
    favoritesProc.generation = root.favoritesSession
    favoritesProc.timedOut = false
    favoritesProc.exited = false
    favoritesProc.exitCode = -1
    favoritesProc.command = [root.interpreterPath, "-I", root.bridgePath, "run",
      "--max-output", String(Model.MAX_FAVORITES_BYTES), "--timeout", "4", "--"].concat(command)
    favoritesTimeout.restart()
    favoritesProc.running = true
  }

  Timer {
    id: favoritesTimer
    interval: 2500
    repeat: true
    running: root.connected
    onTriggered: root.refreshFavorites()
  }

  // ------------------------------------------------------------- search

  property var searchResults: []
  property bool searching: false
  property int searchSession: 0

  Process {
    id: searchProc
    property int generation: -1
    command: []
    stdout: SplitParser {
      id: searchOut
      property string buffer: ""
      onRead: function(data) {
        if (searchProc.generation !== root.searchSession) return
        var chunk = String(data || "")
        buffer += chunk
        while (true) {
          var index = buffer.indexOf("\n")
          if (index < 0) break
          var line = buffer.slice(0, index).trim()
          buffer = buffer.slice(index + 1)
          if (!line) continue
          try {
            var obj = JSON.parse(line)
            if (Array.isArray(obj)) {
              root.searchResults = obj
            } else if (obj && Array.isArray(obj.results)) {
              root.searchResults = obj.results
            }
          } catch (e) {
            // ignore unparseable lines
          }
        }
      }
    }
    stderr: SplitParser {
      onRead: function(line) { root.logStderr("search", line) }
    }
    onExited: function(exitCode) {
      if (searchProc.generation !== root.searchSession) return
      root.searching = false
      searchProc.running = false
    }
  }

  function search(query) {
    if (searching || !query || !query.trim()) return
    root.searching = true
    root.searchResults = []
    root.searchSession++
    searchProc.generation = root.searchSession
    searchOut.buffer = ""
    var command = root.cliampCommand(["remote", "call", "search", "--params",
      JSON.stringify({ query: query.trim() })])
    if (command.length === 0) {
      root.searching = false
      root.lastError = "cliamp executable is invalid"
      return
    }
    searchProc.command = [root.interpreterPath, "-I", root.bridgePath, "run",
      "--max-output", "65536", "--timeout", "8", "--"].concat(command)
    searchProc.running = true
  }

  // ---------------------------------------------------------------- queue
  //
  // queue.list and every queue mutation run through the bounded command
  // runner, so they are serialized with the rest of the IPC traffic. A list
  // response is only applied when its session, mutation revision, and the
  // snapshot's playlist revision still match the request.

  function setQueueVisible(value) {
    var visible = value === true
    if (root.queueVisible === visible) {
      if (visible) root.refreshQueue()
      return
    }
    root.queueVisible = visible
    if (visible) root.refreshQueue()
  }

  function refreshQueue() {
    if (!root.connected) {
      root.queueLoading = false
      root.queueMutating = false
      root.queueRefreshPending = false
      root.queueError = root.lastError || "Cliamp is not running"
      return false
    }
    if (root.queueLoading || root.queueMutating) {
      root.queueRefreshPending = true
      return false
    }
    var limit = Model.clampInt(root.queuePageSize, 1, Model.MAX_QUEUE_ROWS, Model.MAX_QUEUE_ROWS)
    var params = JSON.stringify({ "offset": 0, "limit": limit })
    var session = ++root.queueSession
    var requestRevision = root.queueRevision
    var mutationRevision = root.queueMutationRevision
    var playlistRevision = root.snapshot.playlistRevision
    root.queueLoading = true
    root.queueRefreshPending = false
    var started = root.runWithCallback(
      ["remote", "call", "queue.list", "--params", params, "--wait"],
      root.queueMaxOutput, function(ok, output) {
        if (session !== root.queueSession) return
        root.queueLoading = false
        if (requestRevision !== root.queueRevision) {
          root.queueRefreshPending = false
          root.refreshQueue()
          return
        }
        if (!ok) {
          root.queueError = "Could not load the cliamp queue"
          if (root.queueRefreshPending) {
            root.queueRefreshPending = false
            root.refreshQueue()
          }
          return
        }
        if (mutationRevision !== root.queueMutationRevision ||
            playlistRevision !== root.snapshot.playlistRevision) {
          // A mutation or an external playlist edit landed while this page
          // was in flight. Drop it and request the current state.
          root.queueRefreshPending = false
          root.refreshQueue()
          return
        }
        var parsed = Model.parseQueueJob(output)
        if (!parsed.ok) {
          root.queueError = "Could not read the cliamp queue"
          if (root.queueRefreshPending) {
            root.queueRefreshPending = false
            root.refreshQueue()
          }
          return
        }
        root.queueTracks = parsed.tracks
        root.queueTotal = parsed.total
        root.queueIndex = parsed.index
        root.queueRevision++
        root.queueError = ""
        if (root.queueRefreshPending) {
          root.queueRefreshPending = false
          root.refreshQueue()
        }
      }, true)
    if (!started) {
      root.queueLoading = false
      root.queueError = "cliamp is not available"
      return false
    }
    return true
  }

  function queueMutation(operation, params, failure) {
    if (!root.connected) {
      root.queueError = "Cliamp is not running"
      return false
    }
    if (root.queueLoading || root.queueMutating) return false
    root.queueMutationRevision++
    root.queueMutating = true
    root.queueError = ""
    var started = root.runWithCallback(
      ["remote", "call", operation, "--params", JSON.stringify(params), "--wait"],
      65536, function(ok, output) {
        root.queueMutating = false
        if (!ok) {
          root.queueRefreshPending = false
          root.queueError = failure
          root.queueRevision++
          return
        }
        root.queueError = ""
        root.refreshQueue()
      }, false)
    if (!started) {
      root.queueMutating = false
      root.queueError = "Could not send the queue command"
      return false
    }
    return true
  }

  function queuePlay(index) {
    var total = root.queueTotal
    if (total <= 0) return false
    var target = Model.clampInt(index, 0, total - 1, -1)
    if (target < 0) return false
    return root.queueMutation("queue.play", { "index": target },
      "Could not play that queue track")
  }

  function queueRemove(index) {
    var total = root.queueTotal
    if (total <= 0) return false
    var target = Model.clampInt(index, 0, total - 1, -1)
    if (target < 0) return false
    return root.queueMutation("queue.remove", { "index": target },
      "Could not remove that queue track")
  }

  function queueMove(index, to) {
    var total = root.queueTotal
    if (total <= 1) return false
    var from = Model.clampInt(index, 0, total - 1, -1)
    var target = Model.clampInt(to, 0, total - 1, -1)
    if (from < 0 || target < 0 || from === target) return false
    return root.queueMutation("queue.move", { "index": from, "to": target },
      "Could not move that queue track")
  }

  function queueClear() {
    if (root.queueTotal <= 0) return false
    return root.queueMutation("queue.clear", {}, "Could not clear the cliamp queue")
  }

  function cliampCommand(args) {
    var executable = Model.safeExecutable(root.cliampPath)
    if (!executable || !Array.isArray(args) || args.length > 16) return []
    var values = [executable]
    for (var i = 0; i < args.length; i++) {
      var value = String(args[i] === undefined || args[i] === null ? "" : args[i])
      if (value.length > Model.MAX_EVENT_LINE || /[\x00-\x1f\x7f]/.test(value)) return []
      values.push(value)
    }
    return values
  }

  function setSleep(minutes) {
    var value = Number(minutes)
    if (!isFinite(value) || value <= 0) return root.cancelSleep()
    value = Math.max(1, Math.min(480, Math.round(value)))
    root.sleepUntil = Date.now() + value * 60 * 1000
    root.sleepRemaining = value * 60
    sleepTimer.restart()
    return "sleeping"
  }

  function cancelSleep() {
    root.sleepUntil = 0
    root.sleepRemaining = 0
    sleepTimer.stop()
    return "off"
  }

  Timer {
    id: sleepTimer
    interval: 5000
    repeat: true
    running: root.sleepUntil > 0
    onTriggered: {
      var remaining = Math.max(0, Math.ceil((root.sleepUntil - Date.now()) / 1000))
      root.sleepRemaining = remaining
      if (remaining > 0) return
      root.sleepUntil = 0
      root.sleepRemaining = 0
      sleepTimer.stop()
      root.run(["pause"])
    }
  }

  function run(args) {
    return root.runWithCallback(args, 65536, null, false)
  }

  // The queue needs command stdout plus a completion signal. Everything still
  // flows through the one bounded process, so a queue.list request cannot
  // overlap a mutation or a playback command.
  function runWithCallback(args, maximum, callback, collect) {
    if (!Array.isArray(args) || args.length > 16) return false
    var safeArgs = []
    for (var i = 0; i < args.length; i++) {
      var value = String(args[i] === undefined || args[i] === null ? "" : args[i])
      if (value.length > Model.MAX_EVENT_LINE || /[\x00-\x1f\x7f]/.test(value)) return false
      safeArgs.push(value)
    }
    var key = Model.commandKey(safeArgs)
    if (!key || root.currentCommandKey === key) return false
    var pending = root.commandQueue.slice(0)
    for (var j = 0; j < pending.length; j++) if (pending[j].key === key) return false
    if (pending.length >= root.maxCommandQueue) {
      root.lastError = "cliamp command queue is full"
      return false
    }
    pending.push({
      "key": key,
      "args": safeArgs,
      "maxOutput": Model.clampInt(maximum, 1024, 1024 * 1024, 65536),
      "callback": typeof callback === "function" ? callback : null,
      "collect": collect === true
    })
    root.commandQueue = pending
    root.commandNext()
    return true
  }

  function commandNext() {
    if (root.commandRunning || root.commandQueue.length === 0) return
    var pending = root.commandQueue.slice(0)
    var job = pending.shift()
    root.commandQueue = pending
    var command = root.boundedRunCommand(job.args, job.maxOutput || 65536)
    if (command.length === 0) {
      root.lastError = "cliamp executable is invalid"
      if (typeof job.callback === "function") job.callback(false, "")
      root.commandNext()
      return
    }
    root.commandRunning = true
    root.currentCommandKey = job.key
    root.currentCommandCallback = job.callback
    root.commandCollect = job.collect === true
    root.commandMaxOutput = job.maxOutput || 65536
    root.commandOutput = ""
    root.commandOverflow = false
    commandProc.generation = ++root.commandGeneration
    commandProc.timedOut = false
    commandProc.command = command
    commandTimeout.restart()
    commandProc.running = true
  }

  function finishCommand(ok) {
    var callback = root.currentCommandCallback
    var output = root.commandOutput
    var overflow = root.commandOverflow
    root.commandRunning = false
    root.currentCommandKey = ""
    root.currentCommandCallback = null
    root.commandCollect = false
    root.commandOutput = ""
    root.commandOverflow = false
    root.commandNext()
    if (typeof callback === "function") callback(ok && !overflow, overflow ? "" : output)
  }

  Process {
    id: commandProc
    property int generation: -1
    property bool timedOut: false
    command: []
    stdout: SplitParser {
      id: commandOut
      onRead: function(data) {
        if (!root.commandCollect) return
        var chunk = String(data || "")
        if (root.commandOutput.length + chunk.length + 1 > root.commandMaxOutput) {
          root.commandOverflow = true
          root.commandOutput = ""
          return
        }
        root.commandOutput += chunk + "\n"
      }
    }
    stderr: SplitParser {
      onRead: function(line) { root.logStderr("command", line) }
    }
    onExited: function(exitCode) {
      if (commandProc.generation !== root.commandGeneration) return
      commandTimeout.stop()
      commandProc.running = false
      commandProc.timedOut = false
      root.finishCommand(exitCode === 0)
    }
  }

  Timer {
    id: commandTimeout
    interval: 10000
    repeat: false
    onTriggered: {
      if (!commandProc.running) return
      commandProc.timedOut = true
      commandProc.signal(15)
      commandProc.running = false
      commandProc.generation = -1
      commandTimeout.stop()
      root.lastError = "cliamp command timed out"
      root.finishCommand(false)
    }
  }

  function openTerminal() {
    var command = root.cliampCommand([])
    if (command.length === 0 || root.bridgePath === "" || root.interpreterPath === "") return
    Quickshell.execDetached([root.interpreterPath, "-I", root.bridgePath,
      "terminal", "--"].concat(command))
  }

  // ------------------------------------------------------------------ timer

  // Advance the displayed position every second while playing. Events carry
  // exact positions but never arrive for playback ticks, so this keeps the
  // pill and seek bar smooth without spamming the daemon.
  readonly property bool playing: Model.playing(root.snapshot)

  Timer {
    id: tickTimer
    interval: 1000
    repeat: true
    running: root.connected && root.playing
    onTriggered: {
      var snap = root.snapshot
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

  // Timers touching the position only make sense while anything is playing;
  // the same connect path that arms the stream also re-onlines position.
  Component.onDestruction: {
    root.settingsFlushPending = false
    root.streamSession++
    root.streamIgnoreSession = root.streamSession
    root.healthSession++
    root.favoritesSession++
    root.guardSession++
    root.daemonSession++
    root.searchSession++
    root.commandGeneration++
    root.commandQueue = []
    root.commandRunning = false
    root.currentCommandKey = ""
    root.currentCommandCallback = null
    root.commandCollect = false
    root.commandOutput = ""
    root.commandOverflow = false
    root.queueSession++
    root.queueLoading = false
    root.queueMutating = false
    root.queueRefreshPending = false
    stream.running = false
    healthProc.running = false
    favoritesProc.running = false
    searchProc.running = false
    daemonProc.running = false
    guardProc.running = false
    commandProc.running = false
    reconnectTimer.stop()
    healthTimeout.stop()
    favoritesTimeout.stop()
    guardTimeout.stop()
    daemonStartTimer.stop()
    commandTimeout.stop()
    healthTimer.stop()
    favoritesTimer.stop()
    streamRestartTimer.stop()
  }

  Component.onCompleted: {
    root.reconnectTry = 0
    root.startStream()
  }

  IpcHandler {
    target: "davidjm.cliamp"

    function sleep(minutes: string): string { return root.setSleep(minutes) }
    function cancelSleep(): string { return root.cancelSleep() }
  }
}