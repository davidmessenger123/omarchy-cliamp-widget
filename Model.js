// Pure helper functions for the Cliamp bar widget. No Qt/QML dependencies so
// the logic stays testable outside the shell.

// Playback states cliamp reports in its runtime snapshot (state field).
var STATE_PLAYING = "playing"
var STATE_PAUSED = "paused"
var STATE_STOPPED = "stopped"
var STATE_DOWN = "down"
var STATE_CONNECTING = "connecting"
var FG = "#cacccc"
var MAX_SAFE_INTEGER = 9007199254740991
var MAX_TEXT_LENGTH = 4096
var MAX_TRACKS = 10000
var MAX_EVENT_LINE = 256 * 1024
var MAX_FAVORITES_BYTES = 256 * 1024
var MAX_FAVORITES_ENTRIES = 2000

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function finiteNumber(value) {
  return typeof value === "number" && isFinite(value)
}

function boundedText(value, max, fallback) {
  if (value === undefined || value === null) return fallback || ""
  var text = String(value)
  if (/[\x00-\x1f\x7f]/.test(text)) return fallback || ""
  return text.length > max ? text.slice(0, max) : text
}

function clampNum(value, min, max, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

function clampInt(value, min, max, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  n = Math.trunc ? Math.trunc(n) : (n < 0 ? Math.ceil(n) : Math.floor(n))
  return Math.max(min, Math.min(max, n))
}

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

function validState(state) {
  if (typeof state !== "string") return false
  var s = state.toLowerCase()
  return s === STATE_PLAYING || s === STATE_PAUSED || s === STATE_STOPPED
}

function validRepeat(repeat) {
  if (repeat === undefined || repeat === null) return true
  var r = String(repeat).toLowerCase()
  return r === "off" || r === "all" || r === "one" || r === "all_tracks" ||
    r === "playlist" || r === "single" || r === "track"
}

function isValidSnapshot(raw) {
  if (!isObject(raw) || !validState(raw.state)) return false
  var numeric = ["revision", "playlist_revision", "position", "duration",
    "volume", "index", "total", "speed"]
  for (var i = 0; i < numeric.length; i++) {
    var key = numeric[i]
    if (raw[key] !== undefined && !finiteNumber(raw[key])) return false
  }
  var booleans = ["seekable", "shuffle", "mono"]
  for (var j = 0; j < booleans.length; j++) {
    if (raw[booleans[j]] !== undefined && typeof raw[booleans[j]] !== "boolean") return false
  }
  if (!validRepeat(raw.repeat)) return false
  var track = (raw.track === undefined || raw.track === null) ? raw.logical_track : raw.track
  if (track !== undefined && !isObject(track)) return false
  if (isObject(track)) {
    var strings = ["title", "artist", "album", "path"]
    for (var k = 0; k < strings.length; k++) {
      if (track[strings[k]] !== undefined && track[strings[k]] !== null &&
          typeof track[strings[k]] !== "string") return false
    }
    if (String(track.path || "").length > MAX_TEXT_LENGTH * 4) return false
  }
  if (raw.eq_preset !== undefined && typeof raw.eq_preset !== "string") return false
  if (raw.eq_bands !== undefined) {
    if (!Array.isArray(raw.eq_bands) || raw.eq_bands.length > 10) return false
    for (var b = 0; b < raw.eq_bands.length; b++) {
      if (!finiteNumber(raw.eq_bands[b])) return false
    }
  }
  if (raw.revision !== undefined && (raw.revision < 0 || raw.revision > MAX_SAFE_INTEGER)) return false
  if (raw.playlist_revision !== undefined &&
      (raw.playlist_revision < 0 || raw.playlist_revision > MAX_SAFE_INTEGER)) return false
  if (raw.position !== undefined && raw.position < 0) return false
  if (raw.duration !== undefined && raw.duration < 0) return false
  return true
}

function parseEvent(line) {
  var text = String(line || "").trim()
  if (text === "" || text.length > MAX_EVENT_LINE) return null
  var obj = null
  try { obj = JSON.parse(text) } catch (e) { return null }
  if (!isObject(obj) || (obj.ok !== undefined && obj.ok !== true)) return null
  var topic = obj.event !== undefined ? obj.event
    : (obj.topic !== undefined ? obj.topic : obj.type)
  if (topic !== undefined && topic !== null &&
      String(topic) !== "runtime.state" && String(topic) !== "runtime.playlist") return null
  var data = obj.data === undefined ? obj.snapshot : obj.data
  var snap = snapshotFrom(data)
  if (!snap) return null
  var seq = -1
  if (obj.seq !== undefined) {
    seq = Number(obj.seq)
    if (!isFinite(seq) || Math.trunc(seq) < 0 || seq > MAX_SAFE_INTEGER) return null
  }
  return { snapshot: snap, event: topic === undefined ? "" : String(topic), seq: seq }
}

function parseEventLine(line) {
  var event = parseEvent(line)
  return event ? event.snapshot : null
}

function snapshotFrom(raw) {
  if (!isValidSnapshot(raw)) return null
  var out = blankSnapshot()
  out.revision = clampInt(raw.revision, 0, MAX_SAFE_INTEGER, 0)
  out.playlistRevision = clampInt(raw.playlist_revision, 0, MAX_SAFE_INTEGER, 0)
  out.state = normalizeState(raw.state)
  var track = isObject(raw.track) ? raw.track : (isObject(raw.logical_track) ? raw.logical_track : {})
  var trackPath = boundedText(track.path, MAX_TEXT_LENGTH * 4, "")
  out.track = {
    title: boundedText(track.title, MAX_TEXT_LENGTH, ""),
    artist: boundedText(track.artist, MAX_TEXT_LENGTH, ""),
    album: boundedText(track.album, MAX_TEXT_LENGTH, ""),
    path: trackPath,
    stream: track.stream === true || track.realtime === true ||
      /^https?:/i.test(trackPath)
  }
  out.position = clampNum(raw.position, 0, Number.MAX_VALUE, 0)
  out.duration = clampNum(raw.duration, 0, Number.MAX_VALUE, 0)
  out.seekable = raw.seekable === true && out.duration > 0
  out.volume = clampNum(raw.volume, -36, 12, 0)
  out.index = clampInt(raw.index, -1, MAX_SAFE_INTEGER, -1)
  out.total = clampInt(raw.total, 0, MAX_SAFE_INTEGER, 0)
  out.shuffle = raw.shuffle === true
  out.repeat = normalizeRepeat(raw.repeat)
  out.mono = raw.mono === true
  out.speed = clampNum(raw.speed, 0.25, 2, 1)
  out.eqPreset = boundedText(raw.eq_preset || "Custom", MAX_TEXT_LENGTH, "Custom")
  if (Array.isArray(raw.eq_bands)) {
    var bands = []
    for (var i = 0; i < raw.eq_bands.length; i++) {
      var b = Number(raw.eq_bands[i])
      bands.push(isFinite(b) ? clampNum(b, -100, 100, 0) : 0)
    }
    out.eqBands = bands
  }
  return out
}

function shouldApplySnapshot(snapshot, lastRevision, currentSession, sourceSession) {
  if (!isObject(snapshot)) return false
  if (currentSession !== undefined && sourceSession !== undefined &&
      currentSession !== sourceSession) return false
  var revision = Number(snapshot.revision)
  if (!isFinite(revision) || revision < 0) return false
  var current = Number(lastRevision)
  if (!isFinite(current) || current < 0) return true
  return revision >= current
}

function normalizeState(state) {
  var s = String(state || "").toLowerCase()
  if (validState(s)) return s
  return STATE_STOPPED
}

function normalizeRepeat(repeat) {
  var r = String(repeat || "")
  var l = r.toLowerCase()
  if (l === "off" || r === "Off") return "Off"
  if (r === "All" || l === "all" || l === "all_tracks" || l === "playlist") return "All"
  if (r === "One" || l === "one" || l === "single" || l === "track") return "One"
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
  var text = String(stdout || "")
  if (text.length > MAX_EVENT_LINE * 4) return empty
  var obj = null
  try { obj = JSON.parse(text) } catch (e) { return empty }
  if (!isObject(obj) || obj.ok !== true || !isObject(obj.job)) return empty
  var job = obj.job
  if (job.state !== "succeeded") return { ok: true, total: 0, index: -1, tracks: [] }
  var result = isObject(job.result) ? job.result : {}
  var rawTracks = Array.isArray(result.tracks) ? result.tracks : []
  if (rawTracks.length > MAX_TRACKS) return empty
  var fallbackIndex = clampInt(result.index, -1, MAX_SAFE_INTEGER, -1)
  var tracks = []
  for (var i = 0; i < rawTracks.length; i++) {
    var raw = rawTracks[i]
    if (!isObject(raw)) continue
    var index = clampInt(raw.index, -1, MAX_SAFE_INTEGER, -1)
    if (index < 0) index = tracks.length
    var path = boundedText(raw.path, MAX_TEXT_LENGTH * 4, "")
    tracks.push({
      index: index,
      title: boundedText(raw.title, MAX_TEXT_LENGTH, ""),
      artist: boundedText(raw.artist, MAX_TEXT_LENGTH, ""),
      album: boundedText(raw.album, MAX_TEXT_LENGTH, ""),
      path: path,
      stream: raw.stream === true || raw.realtime === true || /^https?:/i.test(path),
      duration: clampNum(raw.duration, 0, Number.MAX_VALUE, 0),
      current: index === fallbackIndex
    })
  }
  return {
    ok: true,
    total: clampInt(result.total, tracks.length, MAX_SAFE_INTEGER, tracks.length),
    index: fallbackIndex,
    tracks: tracks
  }
}

function stripTomlComment(value) {
  var quote = ""
  var escaped = false
  for (var i = 0; i < value.length; i++) {
    var ch = value.charAt(i)
    if (quote === "\"") {
      if (escaped) escaped = false
      else if (ch === "\\") escaped = true
      else if (ch === quote) quote = ""
    } else if (quote === "'") {
      if (ch === quote) quote = ""
    } else if (ch === "\"" || ch === "'") {
      quote = ch
    } else if (ch === "#") {
      return value.slice(0, i).trim()
    }
  }
  return value.trim()
}

function parseTomlValue(value) {
  var text = stripTomlComment(String(value || "").trim())
  if (text.length > MAX_TEXT_LENGTH * 4) return null
  if (text.charAt(0) === "\"") {
    try {
      var decoded = JSON.parse(text)
      return typeof decoded === "string" ? decoded : null
    } catch (e) {
      return null
    }
  }
  if (text.charAt(0) === "'" && text.charAt(text.length - 1) === "'") {
    return text.slice(1, -1)
  }
  return text
}

function parseFavoritesToml(text) {
  var body = String(text || "")
  if (body.length > MAX_FAVORITES_BYTES) return null
  var lines = body.split(/\r?\n/)
  if (lines.length > MAX_FAVORITES_ENTRIES * 8) return null
  var entries = []
  var entry = null
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].length > MAX_TEXT_LENGTH * 4) return null
    var line = stripTomlComment(lines[i]).trim()
    if (line === "") continue
    if (/^\[\[\s*entry\s*\]\]$/.test(line)) {
      if (entries.length >= MAX_FAVORITES_ENTRIES) return null
      entry = { path: "", title: "", realtime: "false" }
      entries.push(entry)
      continue
    }
    if (!entry || line.charAt(0) === "[") continue
    var eq = line.indexOf("=")
    if (eq < 0) continue
    var key = line.slice(0, eq).trim().replace(/-/g, "_")
    if (key !== "path" && key !== "title" && key !== "realtime") continue
    var value = parseTomlValue(line.slice(eq + 1))
    if (value !== null) entry[key] = value
  }
  var tracks = []
  for (var j = 0; j < entries.length; j++) {
    var item = entries[j]
    if (!item.path) continue
    var path = String(item.path).trim()
    if (!path || path.length > MAX_TEXT_LENGTH * 4 || /[\x00-\x1f\x7f]/.test(path)) continue
    var title = String(item.title || "").trim()
    if (title === "") {
      title = path.replace(/^\w+:\/\//, "").replace(/^.*\//, "").replace(/\?.*$/, "")
    }
    tracks.push({
      index: tracks.length,
      title: boundedText(title, MAX_TEXT_LENGTH, ""),
      artist: "",
      album: "",
      path: path,
      stream: String(item.realtime).toLowerCase() === "true" || /^https?:/i.test(path),
      duration: 0,
      current: false
    })
  }
  return tracks
}

// Volume slider range used by the widget. cliamp's --vol dB range is
// [-30, +6]; the snapshot reports whatever the daemon holds.
function safeFavoritesPath(home) {
  var base = String(home || "")
  if (base.length === 0 || base.length > 4096 || base.charAt(0) !== "/" ||
      base.indexOf("\x00") !== -1 || /[\x00-\x1f\x7f]/.test(base) ||
      base.split("/").some(function(part) { return part === ".." })) return ""
  while (base.length > 1 && base.charAt(base.length - 1) === "/") base = base.slice(0, -1)
  return base + "/.config/cliamp/favorites.toml"
}

function safePid(value) {
  var text = String(value || "").trim()
  if (!/^[1-9][0-9]{0,9}$/.test(text)) return 0
  var pid = Number(text)
  return pid > 1 && pid <= 2147483647 ? pid : 0
}

function safeExecutable(value) {
  var text = String(value || "").trim()
  if (!text || text.length > 4096 || /[\x00-\x1f\x7f]/.test(text)) return ""
  return text
}

function scriptPath(url) {
  var text = String(url || "")
  if (text.indexOf("file://") !== 0) return ""
  text = text.slice(7)
  if (!text || text.length > 4096 || text.charAt(0) !== "/" ||
      /[\x00-\x1f\x7f]/.test(text) || text.split("/").some(function(part) { return part === ".." })) return ""
  return text
}

function commandKey(args) {
  if (!Array.isArray(args)) return ""
  var values = []
  for (var i = 0; i < args.length; i++) {
    var value = String(args[i] === undefined || args[i] === null ? "" : args[i])
    if (value.length > 256 || /[\x00-\x1f\x7f]/.test(value)) return ""
    values.push(value)
  }
  return values.join("\u001f")
}

function boundedSettings(value) {
  if (!isObject(value)) return {}
  var result = {}
  var keys = ["binary", "favPollMs", "reconnectMs", "reconnectCapMs"]
  for (var i = 0; i < keys.length; i++) {
    var key = keys[i]
    if (value[key] === undefined || value[key] === null) continue
    if (key === "binary" && typeof value[key] === "string" && !/[\x00-\x1f\x7f]/.test(value[key]))
      result[key] = value[key].slice(0, 4096)
    else if (key !== "binary" && (typeof value[key] === "number" || typeof value[key] === "string") &&
        String(value[key]).length <= 64 && !/[\x00-\x1f\x7f]/.test(String(value[key])))
      result[key] = value[key]
  }
  return result
}

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
    parseEvent: parseEvent,
    parseEventLine: parseEventLine,
    isValidSnapshot: isValidSnapshot,
    snapshotFrom: snapshotFrom,
    shouldApplySnapshot: shouldApplySnapshot,
    parseQueueJob: parseQueueJob,
    parseFavoritesToml: parseFavoritesToml,
    safeFavoritesPath: safeFavoritesPath,
    safePid: safePid,
    safeExecutable: safeExecutable,
    scriptPath: scriptPath,
    commandKey: commandKey,
    boundedSettings: boundedSettings,
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
    VOL_MAX: VOL_MAX,
    MAX_SAFE_INTEGER: MAX_SAFE_INTEGER,
    MAX_TEXT_LENGTH: MAX_TEXT_LENGTH,
    MAX_TRACKS: MAX_TRACKS,
    MAX_EVENT_LINE: MAX_EVENT_LINE,
    MAX_FAVORITES_BYTES: MAX_FAVORITES_BYTES,
    MAX_FAVORITES_ENTRIES: MAX_FAVORITES_ENTRIES
  }
}