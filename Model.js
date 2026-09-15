// Pure helper functions for the Cliamp bar widget. No Qt/QML dependencies so
// the logic stays testable outside the shell.

// Playback states cliamp reports in its runtime snapshot (state field).
var STATE_PLAYING = "playing"
var STATE_PAUSED = "paused"
var STATE_STOPPED = "stopped"

// Widget-level pseudo-states for the pill when the daemon is unreachable or
// the widget is reconnecting.
var STATE_DOWN = "down"
var STATE_CONNECTING = "connecting"

// Fallback color used for neutral foreground-only rendering.
var FG = "#cacccc"

function clampNum(value, min, max, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

function clampInt(value, min, max, fallback) {
  var n = parseInt(String(value), 10)
  if (isNaN(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

// A clean, empty snapshot shape. Every field the widget reads must exist so
// bindings never dereference null mid-connect.
function blankSnapshot() {
  return {
    revision: 0,
    playlistRevision: 0,
    state: STATE_STOPPED,
    track: { title: "", artist: "", album: "", path: "", stream: false },
    position: 0,
    duration: 0,
    seekable: false,
    volume: 0,
    index: -1,
    total: 0,
    shuffle: false,
    repeat: "Off",
    mono: false,
    speed: 1,
    eqPreset: "Custom",
    eqBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  }
}

// Parse one newline-delimited event from `cliamp remote events`. Both
// runtime.state and runtime.playlist events carry a full snapshot in `data`,
// so a single parser covers both topics. Returns null for malformed lines or
// events that do not look like snapshots.
function parseEventLine(line) {
  var text = String(line || "").trim()
  if (text === "") return null
  var obj = null
  try { obj = JSON.parse(text) } catch (e) { return null }
  if (!obj || typeof obj !== "object") return null
  var data = obj.data || obj.snapshot || null
  if (!data || typeof data !== "object") return null
  return snapshotFrom(data)
}

// Normalize cliamp's raw snapshot JSON onto the widget's flat shape. Works
// for `remote events` data, `remote state` snapshot, and the snapshot nested
// inside a completed job.
function snapshotFrom(raw) {
  if (!raw || typeof raw !== "object") return blankSnapshot()
  var out = blankSnapshot()
  out.revision = clampInt(raw.revision, 0, Number.MAX_SAFE_INTEGER, 0)
  out.playlistRevision = clampInt(raw.playlist_revision, 0, Number.MAX_SAFE_INTEGER, 0)
  out.state = normalizeState(raw.state)
  var track = raw.track && typeof raw.track === "object" ? raw.track : (raw.logical_track || {})
  out.track = {
    title: String(track.title || ""),
    artist: String(track.artist || ""),
    album: String(track.album || ""),
    path: String(track.path || ""),
    stream: track.stream === true || track.realtime === true ||
      /^https?:/.test(String(track.path || ""))
  }
  out.position = clampNum(raw.position, 0, Number.MAX_VALUE, 0)
  out.duration = clampNum(raw.duration, 0, Number.MAX_VALUE, 0)
  out.seekable = raw.seekable === true && out.duration > 0
  out.volume = clampNum(raw.volume, -36, 12, 0)
  out.index = clampInt(raw.index, -1, Number.MAX_SAFE_INTEGER, -1)
  out.total = clampInt(raw.total, 0, Number.MAX_SAFE_INTEGER, 0)
  out.shuffle = raw.shuffle === true
  out.repeat = normalizeRepeat(raw.repeat)
  out.mono = raw.mono === true
  out.speed = clampNum(raw.speed, 0.25, 2, 1)
  out.eqPreset = String(raw.eq_preset || "Custom")
  if (Array.isArray(raw.eq_bands)) {
    var bands = []
    for (var i = 0; i < Math.min(raw.eq_bands.length, 10); i++) {
      var b = Number(raw.eq_bands[i])
      bands.push(isFinite(b) ? b : 0)
    }
    out.eqBands = bands
  }
  return out
}

function normalizeState(state) {
  var s = String(state || "").toLowerCase()
  if (s === STATE_PLAYING || s === STATE_PAUSED || s === STATE_STOPPED) return s
  return STATE_STOPPED
}

function normalizeRepeat(repeat) {
  var r = String(repeat || "")
  if (r === "Off" || r === "All" || r === "One") return r
  var l = r.toLowerCase()
  if (l === "all" || l === "all_tracks" || l === "playlist") return "All"
  if (l === "one" || l === "single" || l === "track") return "One"
  return "Off"
}

// Track glyph shown in the popup header. Streams get a radio glyph, files get
// a music note.
function trackGlyph(snapshot) {
  if (!snapshot || !snapshot.track) return "\uf001"
  return isStream(snapshot) ? "\uf1d1" : "\uf001"
}

function isStream(snapshot) {
  return !!(snapshot && snapshot.track && snapshot.track.stream)
}

function playing(snapshot) {
  return !!(snapshot && snapshot.state === STATE_PLAYING)
}

function paused(snapshot) {
  return !!(snapshot && snapshot.state === STATE_PAUSED)
}

// Human label for the pill & status line, e.g. "All systems green" is not a
// thing here — this is "Lofi Jam · John Bartmann" or "Nothing playing".
function statusLine(snapshot) {
  if (!snapshot) return "Cliamp is not running"
  if (snapshot.state === STATE_STOPPED) return "Nothing playing"
  var track = snapshot.track || {}
  var parts = []
  if (track.title) parts.push(track.title)
  if (track.artist && track.artist !== track.title) parts.push(track.artist)
  if (parts.length === 0) parts.push(isStream(snapshot) ? "Radio stream" : "Unknown track")
  return parts.join(" · ")
}

function formatTime(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var sec = s % 60
  var mm = (m < 10 ? "0" : "") + m
  var ss = (sec < 10 ? "0" : "") + sec
  return h > 0 ? h + ":" + mm + ":" + ss : m + ":" + ss
}

// "1:43 / 3:18" for seekable tracks, "LIVE · 3:18" for streams, "—" otherwise.
function timeRange(snapshot, displayPosition) {
  if (!snapshot) return ""
  if (isStream(snapshot)) {
    var stamp = formatTime(displayPosition)
    return stamp !== "" ? "LIVE · " + stamp : "LIVE"
  }
  if (snapshot.duration > 0)
    return formatTime(displayPosition) + " / " + formatTime(snapshot.duration)
  return formatTime(displayPosition)
}

// Detail line used under the title and in the pill tooltip.
function subtitleLine(snapshot) {
  if (!snapshot) return ""
  var parts = []
  var track = snapshot.track || {}
  if (track.album) parts.push(track.album)
  if (isStream(snapshot)) parts.push("stream")
  if (snapshot.speed !== 1) parts.push(snapshot.speed.toFixed(2) + "x")
  if (snapshot.repeat !== "Off") parts.push("repeat " + snapshot.repeat.toLowerCase())
  if (snapshot.shuffle) parts.push("shuffle")
  if (snapshot.mono) parts.push("mono")
  if (parts.length === 0) return ""
  return parts.join(" · ")
}

// Compact mode chips for the footer, same data as subtitleLine but without
// repeating "repeat off" spam.
function modeChips(snapshot) {
  if (!snapshot) return []
  var chips = []
  if (snapshot.speed !== 1) chips.push(snapshot.speed.toFixed(2) + "x")
  if (snapshot.repeat !== "Off") chips.push("repeat " + snapshot.repeat.toLowerCase())
  if (snapshot.shuffle) chips.push("shuffle")
  if (snapshot.mono) chips.push("mono")
  return chips
}

// Parse the completed `cliamp remote call queue.list --params ... --wait`
// job response into {ok, total, index, tracks}. Tracks are normalized to
// {title, artist, duration, path, index, stream, current}.
function parseQueueJob(stdout) {
  var empty = { ok: false, total: 0, index: -1, tracks: [] }
  var obj = null
  try { obj = JSON.parse(String(stdout || "")) } catch (e) { return empty }
  if (!obj || !obj.ok) return empty
  var job = obj.job || {}
  if (job.state !== "succeeded") return { ok: true, total: 0, index: -1, tracks: [] }
  var result = job.result || {}
  var rawTracks = Array.isArray(result.tracks) ? result.tracks : []
  var older = 0
  var fallbackIndex = clampInt(result.index, -1, Number.MAX_SAFE_INTEGER, -1)
  var tracks = []
  for (var i = 0; i < rawTracks.length; i++) {
    var raw = rawTracks[i] || {}
    var index = clampInt(raw.index, -1, Number.MAX_SAFE_INTEGER, -1)
    if (index < 0) index = older++
    var duration = clampNum(raw.duration, 0, Number.MAX_VALUE, 0)
    tracks.push({
      index: index,
      title: String(raw.title || ""),
      artist: String(raw.artist || ""),
      album: String(raw.album || ""),
      path: String(raw.path || ""),
      stream: raw.stream === true || raw.realtime === true ||
        /^https?:/.test(String(raw.path || "")),
      duration: duration,
      current: index === fallbackIndex
    })
  }
  return {
    ok: true,
    total: clampInt(result.total, tracks.length, Number.MAX_SAFE_INTEGER, tracks.length),
    index: fallbackIndex,
    tracks: tracks
  }
}

// Parse cliamp's favorites.toml — a list of [[entry]] blocks carrying
// path/title/favorited_at/realtime — into the same track-ish shape the panel
// rows use. Preserves file order and always yields real objects.
function parseFavoritesToml(text) {
  var entries = []
  var entry = null
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "" || line[0] === "#") continue
    if (line === "[[entry]]") {
      entry = { path: "", title: "", realtime: "false" }
      entries.push(entry)
      continue
    }
    if (!entry) continue
    var m = /^(\w+)\s*=\s*"(.*)"$/.exec(line)
    if (m) { entry[m[1]] = m[2]; continue }
    m = /^(\w+)\s*=\s*(\S+)$/.exec(line)
    if (m) entry[m[1]] = m[2]
  }
  var tracks = []
  for (var j = 0; j < entries.length; j++) {
    var t = entries[j]
    if (!t.path) continue
    var title = String(t.title || "").trim()
    if (title === "") {
      title = String(t.path).replace(/^\w+:\/\//, "").replace(/^.*\//, "").replace(/\?.*$/, "")
    }
    tracks.push({
      index: j,
      title: title,
      artist: "",
      album: "",
      path: String(t.path),
      stream: String(t.realtime).toLowerCase() === "true" ||
        /^https?:/.test(String(t.path || "")),
      duration: 0,
      current: false
    })
  }
  return tracks
}

// Volume slider range used by the widget. cliamp's --vol dB range is
// [-30, +6]; the snapshot reports whatever the daemon holds.
var VOL_MIN = -30
var VOL_MAX = 6

function volumeLabel(db) {
  var v = clampNum(db, -36, 12, 0)
  if (v <= -30) return "muted"
  return (v > 0 ? "+" : "") + v + " dB"
}

function eqBandPeak(bands) {
  var peak = 0
  for (var i = 0; i < (bands || []).length; i++) {
    var v = Math.abs(Number(bands[i]) || 0)
    if (v > peak) peak = v
  }
  return peak
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    STATE_PLAYING: STATE_PLAYING,
    STATE_PAUSED: STATE_PAUSED,
    STATE_STOPPED: STATE_STOPPED,
    STATE_DOWN: STATE_DOWN,
    STATE_CONNECTING: STATE_CONNECTING,
    blankSnapshot: blankSnapshot,
    parseEventLine: parseEventLine,
    snapshotFrom: snapshotFrom,
    parseQueueJob: parseQueueJob,
    parseFavoritesToml: parseFavoritesToml,
    clampNum: clampNum,
    clampInt: clampInt,
    formatTime: formatTime,
    timeRange: timeRange,
    statusLine: statusLine,
    subtitleLine: subtitleLine,
    modeChips: modeChips,
    trackGlyph: trackGlyph,
    isStream: isStream,
    playing: playing,
    paused: paused,
    volumeLabel: volumeLabel,
    eqBandPeak: eqBandPeak,
    VOL_MIN: VOL_MIN,
    VOL_MAX: VOL_MAX
  }
}