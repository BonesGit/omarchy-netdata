.pragma library

// Netdata v3 helpers for the bar widget. Keep this file free of QML
// objects so Panel, Poller, and the chart can share the same parsing.

var DEFAULT_HOST = "localhost"
var NVIDIA_CONTEXT = "nvidia_smi.gpu_utilization"
var DEFAULT_CONTEXT = NVIDIA_CONTEXT
var DEFAULT_TITLE = "GPU utilization"
var DEFAULT_TEMP_TITLE = "GPU temperature"
var NVIDIA_TEMP_CONTEXT = "nvidia_smi.gpu_temperature"
var AMD_CONTEXT = "amdgpu.gpu_utilization"
var AMD_TEMP_CONTEXT = "system.hw.sensor.temperature.input"
var AMD_TEMP_SCOPE = "*amdgpu*"
var GPU_NVIDIA = "nvidia"
var GPU_AMD = "amd"
var GPU_PRESETS = {
  nvidia: { context: NVIDIA_CONTEXT, tempContext: NVIDIA_TEMP_CONTEXT, tempScope: "" },
  amd: { context: AMD_CONTEXT, tempContext: AMD_TEMP_CONTEXT, tempScope: AMD_TEMP_SCOPE }
}
var DEFAULT_PORT = "19999"
var MIN_WINDOW_SEC = 60
var MAX_WINDOW_SEC = 3 * 24 * 60 * 60
var DEFAULT_WINDOW_SEC = 10 * 60
var LOW_USAGE = 30
var HIGH_USAGE = 70
var HOUR_SEC = 60 * 60
var DAY_SEC = 24 * HOUR_SEC
var MAX_LATEST_RESPONSE_BYTES = 256 * 1024
var MAX_HISTORY_RESPONSE_BYTES = 2 * 1024 * 1024
// Liveness-probe cap: while offline the poller keeps trying, at most
// once every 5 minutes.
var BACKOFF_MAX_MS = 5 * 60 * 1000
// Maximum continuous retry window: after this much continuous retrying
// without a success, the poller auto-stops (user must restart). Expressed
// in minutes; user-settable via retryWindowMinutes (default 2 hours).
var DEFAULT_RETRY_WINDOW_MIN = 120
var MIN_RETRY_WINDOW_MIN = 1
var MAX_RETRY_WINDOW_MIN = 1440
// Hard cap independent of server timestamps. 2s polling over 3 days is
// ~129600 points; a hostile clock can stay inside the window forever.
var MAX_POINTS = 2048

function defaultHost() { return DEFAULT_HOST }
function defaultTitle() { return DEFAULT_TITLE }
function defaultTempTitle() { return DEFAULT_TEMP_TITLE }
function defaultWindowSec() { return DEFAULT_WINDOW_SEC }
function maxWindowSec() { return MAX_WINDOW_SEC }
function maxLatestResponseBytes() { return MAX_LATEST_RESPONSE_BYTES }
function maxHistoryResponseBytes() { return MAX_HISTORY_RESPONSE_BYTES }
function maxPoints() { return MAX_POINTS }

function responseWithinLimit(raw, maxBytes) {
  var limit = Number(maxBytes)
  if (!isFinite(limit) || limit <= 0) return true
  return String(raw || "").length <= limit
}

// Mid-stream size check for StdioCollector.data. Prefer byteLength so a
// hostile body is measured as buffered bytes, not UTF-16 string length.
function collectorByteLength(data) {
  if (data === null || data === undefined) return 0
  if (typeof data.byteLength === "number" && isFinite(data.byteLength)) return data.byteLength
  if (typeof data.length === "number" && isFinite(data.length)) return data.length
  return String(data).length
}

function collectorOverLimit(data, maxBytes) {
  var limit = Number(maxBytes)
  if (!isFinite(limit) || limit <= 0) return false
  return collectorByteLength(data) > limit
}

function presetDuration(id) {
  if (id === "1h") return HOUR_SEC
  if (id === "3h") return 3 * HOUR_SEC
  if (id === "6h") return 6 * HOUR_SEC
  if (id === "24h") return 24 * HOUR_SEC
  if (id === "2d") return 2 * DAY_SEC
  if (id === "3d") return 3 * DAY_SEC
  return DEFAULT_WINDOW_SEC
}

function clamp(value, min, max) {
  var n = Number(value)
  if (!isFinite(n)) return min
  return Math.max(min, Math.min(max, n))
}

function nowSec() {
  return Date.now() / 1000
}

function configuredHost(settings) {
  var raw = settings && settings.host !== undefined && settings.host !== null ? settings.host : DEFAULT_HOST
  return String(raw || DEFAULT_HOST).replace(/^\s+|\s+$/g, "") || DEFAULT_HOST
}

function settingString(settings, key) {
  if (!settings || settings[key] === undefined || settings[key] === null) return ""
  return String(settings[key]).replace(/^\s+|\s+$/g, "")
}

function normalizeGpu(value) {
  var s = String(value || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  if (s === GPU_AMD) return GPU_AMD
  return GPU_NVIDIA
}

// Blank or nvidia -> nvidia presets. amd -> amd presets.
function resolvedGpu(settings) {
  return normalizeGpu(settings && settings.gpu)
}

function gpuPreset(gpu) {
  return GPU_PRESETS[gpu] || GPU_PRESETS[GPU_NVIDIA]
}

function contextOverride(settings) {
  return settingString(settings, "context")
}

function tempContextOverride(settings) {
  return settingString(settings, "tempContext")
}

function configuredContext(settings) {
  var override = contextOverride(settings)
  if (override) return override
  return gpuPreset(resolvedGpu(settings)).context
}

function isTemperatureContext(context) {
  return String(context || "").toLowerCase().indexOf("temp") >= 0
}

// Companion GPU temp for the popup. NVIDIA has its own context;
// AMD exposes edge temp as a sensors instance, not amdgpu.*.
function derivedTempQuery(context) {
  var ctx = String(context || "")
  if (!ctx) return { context: "", scopeInstances: "" }
  if (ctx.indexOf("nvidia_smi.") === 0) {
    if (isTemperatureContext(ctx)) return { context: "", scopeInstances: "" }
    return { context: NVIDIA_TEMP_CONTEXT, scopeInstances: "" }
  }
  if (ctx.indexOf("amdgpu.") === 0)
    return { context: AMD_TEMP_CONTEXT, scopeInstances: AMD_TEMP_SCOPE }
  if (ctx === AMD_TEMP_CONTEXT)
    return { context: ctx, scopeInstances: AMD_TEMP_SCOPE }
  return { context: "", scopeInstances: "" }
}

function configuredTempQuery(settings) {
  var util = configuredContext(settings)
  var tempOver = tempContextOverride(settings)
  if (tempOver) {
    if (tempOver === util) return { context: "", scopeInstances: "" }
    var extra = derivedTempQuery(tempOver)
    return {
      context: tempOver,
      scopeInstances: extra.scopeInstances || (tempOver === AMD_TEMP_CONTEXT ? AMD_TEMP_SCOPE : "")
    }
  }
  if (contextOverride(settings)) return derivedTempQuery(util)
  var preset = gpuPreset(resolvedGpu(settings))
  return { context: preset.tempContext, scopeInstances: preset.tempScope }
}

function configuredDashboardUrl(settings) {
  var raw = settings && settings.dashboardUrl !== undefined && settings.dashboardUrl !== null ? settings.dashboardUrl : ""
  var override = String(raw || "").replace(/^\s+|\s+$/g, "")
  if (override) {
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(override)) return override
    return "http://" + override
  }
  return parseHost(configuredHost(settings)).origin
}

function configuredRefreshMs(settings) {
  var n = parseInt(settings && settings.refreshSeconds, 10)
  if (!isFinite(n)) n = 5
  return Math.max(2, Math.min(60, n)) * 1000
}

function configuredRetryAttempts(settings) {
  var n = parseInt(settings && settings.retryAttempts, 10)
  if (!isFinite(n)) n = 5
  return Math.max(1, Math.min(60, n))
}

// Maximum continuous retry window in ms (default 2 hours). After this
// much time has passed since the first failure in a streak without a
// successful poll, the poller auto-stops.
function configuredRetryWindowMs(settings) {
  var n = parseInt(settings && settings.retryWindowMinutes, 10)
  if (!isFinite(n)) n = DEFAULT_RETRY_WINDOW_MIN
  var minutes = Math.max(MIN_RETRY_WINDOW_MIN, Math.min(MAX_RETRY_WINDOW_MIN, n))
  return minutes * 60 * 1000
}

// Backed-off interval after `failCount` consecutive failed polls: the
// first `retryAttempts` polls stay at the base refresh, then the wait
// doubles each poll, capped at the liveness-probe max (5 min). So with
// the defaults (5 attempts, 5s base) polls 1-5 run at 5s, poll 6 at 10s,
// poll 7 at 20s, ... until it settles on a 5-minute liveness probe.
function backoffMs(failCount, baseMs, retryAttempts) {
  var n = Math.max(0, Math.floor(failCount))
  var base = Math.max(1, Math.floor(baseMs))
  var attempts = parseInt(retryAttempts, 10)
  if (!isFinite(attempts)) attempts = 5
  attempts = Math.max(1, attempts)
  var excess = Math.max(0, n - attempts + 1)
  var ms = base
  for (var i = 0; i < excess; i++) ms *= 2
  return Math.min(ms, BACKOFF_MAX_MS)
}

// Accepts "localhost", "localhost:19999", "http://localhost:19999", or
// an IP. Default scheme is http; default port is 19999.
function parseHost(raw) {
  var value = String(raw || DEFAULT_HOST).replace(/^\s+|\s+$/g, "")
  if (!value) value = DEFAULT_HOST

  var scheme = "http"
  var rest = value
  var schemeMatch = value.match(/^(https?):\/\/(.+)$/i)
  if (schemeMatch) {
    scheme = schemeMatch[1].toLowerCase()
    rest = schemeMatch[2]
  }
  rest = rest.replace(/\/+$/, "")

  var host = rest
  var port = DEFAULT_PORT
  var bracket = rest.match(/^\[([^\]]+)\](?::(\d+))?$/)
  if (bracket) {
    host = bracket[1]
    if (bracket[2]) port = bracket[2]
  } else {
    var lastColon = rest.lastIndexOf(":")
    if (lastColon > 0 && rest.indexOf(":") === lastColon && /^\d+$/.test(rest.slice(lastColon + 1))) {
      host = rest.slice(0, lastColon)
      port = rest.slice(lastColon + 1)
    }
  }

  return {
    scheme: scheme,
    host: host,
    port: port,
    origin: scheme + "://" + host + ":" + port,
    label: safeHostLabel(host)
  }
}

// Display-only. Settings can be markup-shaped; AutoText and first-party
// tooltip Text must never see <img>/<a>/path junk as a label.
function isIPv4(value) {
  var parts = String(value || "").split(".")
  if (parts.length !== 4) return false
  for (var i = 0; i < 4; i++) {
    if (!/^\d{1,3}$/.test(parts[i])) return false
    var n = Number(parts[i])
    if (n > 255) return false
  }
  return true
}

function ipv6GroupsValid(groups, allowIpv4Tail) {
  if (!groups || !groups.length) return false
  for (var i = 0; i < groups.length; i++) {
    var g = groups[i]
    if (allowIpv4Tail && i === groups.length - 1 && g.indexOf(".") >= 0)
      return isIPv4(g)
    if (!/^[0-9A-Fa-f]{1,4}$/.test(g)) return false
  }
  return true
}

function isIPv6(value) {
  var s = String(value || "")
  if (!s || s.indexOf(":") < 0) return false
  if (s.charAt(0) === "[" || s.indexOf("%") >= 0) return false
  var halves = s.split("::")
  if (halves.length > 2) return false
  if (halves.length === 2) {
    var left = halves[0] === "" ? [] : halves[0].split(":")
    var right = halves[1] === "" ? [] : halves[1].split(":")
    if (left.length + right.length > 7) return false
    if (halves[0] !== "" && !ipv6GroupsValid(left, false)) return false
    if (halves[1] !== "" && !ipv6GroupsValid(right, true)) return false
    return true
  }
  var groups = s.split(":")
  if (groups.length === 8) return ipv6GroupsValid(groups, false)
  if (groups.length === 7 && groups[6].indexOf(".") >= 0) return ipv6GroupsValid(groups, true)
  return false
}

function isHostname(value) {
  var s = String(value || "")
  if (!s || s.length > 253) return false
  if (s.charAt(s.length - 1) === ".") s = s.slice(0, -1)
  if (!s || s.length > 253) return false
  var labels = s.split(".")
  for (var i = 0; i < labels.length; i++) {
    var lab = labels[i]
    if (lab.length < 1 || lab.length > 63) return false
    if (!/^[A-Za-z0-9-]+$/.test(lab)) return false
    if (lab.charAt(0) === "-" || lab.charAt(lab.length - 1) === "-") return false
  }
  return true
}

function isSafeHostLabel(value) {
  var s = String(value || "")
  return isIPv4(s) || isIPv6(s) || isHostname(s)
}

function safeHostLabel(value) {
  var s = String(value || "")
  return isSafeHostLabel(s) ? s : DEFAULT_HOST
}

function hostLabel(raw) {
  return parseHost(raw).label
}

function dataUrl(rawHost, context, after, before, points, extra) {
  var parsed = parseHost(rawHost)
  var ctx = encodeURIComponent(context || DEFAULT_CONTEXT)
  var url = parsed.origin + "/api/v3/data?contexts=" + ctx
    + "&after=" + encodeURIComponent(String(after))
    + "&points=" + encodeURIComponent(String(Math.max(2, Math.round(points || 120))))
    + "&group=average&format=json"
  if (before !== undefined && before !== null && before !== "")
    url += "&before=" + encodeURIComponent(String(before))
  var scope = extra && extra.scopeInstances ? String(extra.scopeInstances) : ""
  if (scope) url += "&scope_instances=" + encodeURIComponent(scope)
  var groupBy = extra && extra.groupBy ? String(extra.groupBy) : ""
  if (groupBy) url += "&group_by=" + encodeURIComponent(groupBy)
  return url
}

// Dual-monitor pills with the same host+charts share one poller.
// split and refreshSeconds update that poller; they do not fork it.
function pollerKey(settings) {
  var origin = parseHost(configuredHost(settings)).origin
  var ctx = configuredContext(settings)
  var temp = configuredTempQuery(settings)
  return origin + "\t" + ctx + "\t" + (temp.context || "") + "\t" + (temp.scopeInstances || "")
}

function configuredSplit(settings) {
  if (!settings || settings.split === undefined || settings.split === null) return false
  var v = settings.split
  if (v === true || v === 1) return true
  if (v === false || v === 0) return false
  var s = String(v).replace(/^\s+|\s+$/g, "").toLowerCase()
  return s === "true" || s === "1"
}

function queryExtra(tempQuery, split) {
  var extra = {}
  if (tempQuery && tempQuery.scopeInstances) extra.scopeInstances = tempQuery.scopeInstances
  if (split) extra.groupBy = "instance"
  return extra
}

function seriesKey(label) {
  var s = String(label || "")
  var m = s.match(/gpu-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i)
  return m ? m[0].toLowerCase() : s
}

function presentNumber(value) {
  if (value === null || value === undefined || value === "") return false
  return isFinite(Number(value))
}

function latestUrl(rawHost, context, extra) {
  return dataUrl(rawHost, context, -60, 0, 12, extra)
}

function historyUrl(rawHost, context, startSec, endSec, points, extra) {
  return dataUrl(rawHost, context, Math.floor(startSec), Math.floor(endSec), points, extra)
}

function parsePayload(raw) {
  var text = String(raw || "").replace(/^\s+|\s+$/g, "")
  if (!text) return null
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

function firstFinite(values) {
  if (!values || !values.length) return null
  for (var i = 0; i < values.length; i++) {
    var n = Number(values[i])
    if (isFinite(n)) return n
  }
  return null
}

function rowValue(row) {
  if (!row || row.length < 2) return null
  // First numeric dimension after time. Extra GPU instances are averaged
  // so a multi-GPU host still yields one utilization number.
  var sum = 0
  var count = 0
  for (var i = 1; i < row.length; i++) {
    var n = Number(row[i])
    if (isFinite(n)) {
      sum += n
      count++
    }
  }
  return count > 0 ? sum / count : null
}

function parseSeries(payload) {
  var result = payload && payload.result ? payload.result : null
  var rows = result && result.data ? result.data : []
  var points = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row || row.length < 1) continue
    var t = Number(row[0])
    if (!isFinite(t)) continue
    points.push({ t: t, v: rowValue(row) })
  }
  points.sort(function(a, b) { return a.t - b.t })
  return points
}

function parseSeriesSplit(payload) {
  var result = payload && payload.result ? payload.result : null
  var rows = result && result.data ? result.data : []
  var labels = result && result.labels ? result.labels : []
  var colCount = 0
  var i, c
  for (i = 0; i < rows.length; i++) {
    if (rows[i] && rows[i].length > colCount) colCount = rows[i].length
  }
  var valueCols = Math.max(0, colCount - 1)
  var cols = []
  for (c = 0; c < valueCols; c++) {
    var label = labels[c + 1] || ""
    cols.push({ key: seriesKey(label), index: c + 1, points: [] })
  }
  for (i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row || row.length < 1) continue
    var t = Number(row[0])
    if (!isFinite(t)) continue
    for (c = 0; c < cols.length; c++) {
      var raw = c + 1 < row.length ? row[c + 1] : null
      var v = null
      if (presentNumber(raw)) v = Number(raw)
      cols[c].points.push({ t: t, v: v })
    }
  }
  var out = []
  for (c = 0; c < cols.length; c++) {
    cols[c].points.sort(function(a, b) { return a.t - b.t })
    out.push({
      name: "GPU" + (c + 1),
      key: cols[c].key,
      points: cols[c].points
    })
  }
  return out
}

function alignSeriesByKey(canonical, other) {
  var list = other || []
  var canon = canonical || []
  if (!canon.length) return list
  var byKey = {}
  var i
  for (i = 0; i < list.length; i++) {
    var key = list[i] && list[i].key ? list[i].key : ""
    byKey[key] = list[i]
  }
  var out = []
  var used = {}
  for (i = 0; i < canon.length; i++) {
    var ck = canon[i] && canon[i].key ? canon[i].key : ""
    var match = byKey[ck]
    if (!match) continue
    out.push({
      name: canon[i].name,
      key: match.key,
      points: match.points
    })
    used[ck] = true
  }
  for (i = 0; i < list.length; i++) {
    var ok = list[i] && list[i].key ? list[i].key : ""
    if (used[ok]) continue
    out.push({
      name: "GPU" + (out.length + 1),
      key: list[i].key,
      points: list[i].points
    })
  }
  return out
}

function latestValuePerSeries(seriesList) {
  var out = []
  var list = seriesList || []
  for (var i = 0; i < list.length; i++) {
    var pts = list[i] && list[i].points
    var found = null
    if (pts) {
      for (var j = pts.length - 1; j >= 0; j--) {
        if (presentNumber(pts[j].v)) {
          found = Number(pts[j].v)
          break
        }
      }
    }
    out.push(found)
  }
  return out
}

function maxOf(values) {
  var hi = null
  if (!values) return null
  for (var i = 0; i < values.length; i++) {
    if (!presentNumber(values[i])) continue
    var n = Number(values[i])
    if (hi === null || n > hi) hi = n
  }
  return hi
}

function mergeSeriesPoint(seriesList, t, vPerSeries) {
  var list = seriesList || []
  var values = vPerSeries || []
  var next = []
  var i
  if (values.length !== list.length) {
    for (i = 0; i < list.length; i++) next.push(list[i])
    return next
  }
  for (i = 0; i < list.length; i++) {
    var src = list[i] || {}
    next.push({
      name: src.name,
      key: src.key,
      points: mergePoint(src.points, t, values[i])
    })
  }
  return next
}

function pruneSeries(seriesList, newestSec) {
  var next = []
  var list = seriesList || []
  for (var i = 0; i < list.length; i++) {
    var src = list[i] || {}
    next.push({
      name: src.name,
      key: src.key,
      points: prunePoints(src.points, newestSec)
    })
  }
  return next
}

function formatValueList(values, formatter, suffix) {
  var extra = suffix ? String(suffix) : ""
  var parts = []
  var list = values || []
  for (var i = 0; i < list.length; i++) {
    var formatted = formatter(list[i])
    if (extra && formatted !== "—") formatted += extra
    parts.push(formatted)
  }
  return parts.join(" / ")
}

function parseMeta(payload) {
  var view = payload && payload.view ? payload.view : {}
  var db = payload && payload.db ? payload.db : {}
  var summary = payload && payload.summary ? payload.summary : {}
  var node = summary.nodes && summary.nodes[0] ? summary.nodes[0] : null
  return {
    title: String(view.title || DEFAULT_TITLE).replace(/^\s+|\s+$/g, "") || DEFAULT_TITLE,
    units: view.units || "%",
    viewAfter: Number(view.after),
    viewBefore: Number(view.before),
    dbFirst: Number(db.first_entry),
    dbLast: Number(db.last_entry),
    nodeName: node && node.nm ? String(node.nm) : ""
  }
}

function latestValue(points) {
  if (!points || !points.length) return null
  for (var i = points.length - 1; i >= 0; i--) {
    var n = Number(points[i].v)
    if (isFinite(n)) return n
  }
  return null
}

function mergePoint(points, t, v) {
  var next = []
  var i
  for (i = 0; i < (points || []).length; i++) next.push(points[i])
  if (!isFinite(Number(t))) return next
  var ts = Number(t)
  for (i = 0; i < next.length; i++) {
    if (next[i].t === ts) {
      next[i] = { t: ts, v: v }
      return next
    }
    if (next[i].t > ts) {
      next.splice(i, 0, { t: ts, v: v })
      return next
    }
  }
  next.push({ t: ts, v: v })
  return next
}

// Drop samples older than the chart's max window, then enforce a hard
// item-count cap. Time prune alone is not enough: live polling at 2s
// retains ~129600 points over three days, and a configured or
// compromised endpoint can keep timestamps inside that window forever.
function prunePoints(points, newestSec) {
  if (!points || !points.length) return []
  var newest = Number(newestSec)
  if (!isFinite(newest) && points.length)
    newest = Number(points[points.length - 1].t)
  var start = 0
  if (isFinite(newest)) {
    var cutoff = newest - MAX_WINDOW_SEC
    while (start < points.length && Number(points[start].t) < cutoff) start++
  }
  if (points.length - start > MAX_POINTS)
    start = points.length - MAX_POINTS
  if (start === 0) return points
  return points.slice(start)
}

function visiblePoints(points, startSec, endSec) {
  var out = []
  var start = Number(startSec)
  var end = Number(endSec)
  if (!points || !isFinite(start) || !isFinite(end)) return out
  for (var i = 0; i < points.length; i++) {
    var p = points[i]
    if (p.t >= start && p.t <= end) out.push(p)
  }
  return out
}

// idle = no reading, low < 30%, mid 30–70%, high > 70%.
function statusKey(connected, value) {
  if (!connected) return "idle"
  // Number(null) is 0, which would look like a live 0% (green)
  // before the first real sample arrives.
  if (value === null || value === undefined || value === "") return "idle"
  var n = Number(value)
  if (!isFinite(n)) return "idle"
  if (n < LOW_USAGE) return "low"
  if (n > HIGH_USAGE) return "high"
  return "mid"
}

function parseHex(hex) {
  var s = String(hex || "")
  var m = s.match(/^#([0-9A-Fa-f]{6})$/)
  if (!m) return null
  return {
    r: parseInt(m[1].substr(0, 2), 16),
    g: parseInt(m[1].substr(2, 2), 16),
    b: parseInt(m[1].substr(4, 2), 16)
  }
}

function isGreenish(hex) {
  var c = parseHex(hex)
  if (!c) return false
  return c.g > c.r + 15 && c.g > c.b
}

function isYellowish(hex) {
  var c = parseHex(hex)
  if (!c) return false
  return c.r > 140 && c.g > 110 && c.b < c.g * 0.75 && Math.abs(c.r - c.g) < 80
}

function parseThemeColors(raw) {
  var found = { green: "", yellow: "" }
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (!match) continue
    if (match[1] === "green") found.green = match[2]
    else if (match[1] === "yellow") found.yellow = match[2]
    else if (match[1] === "color2" && !found.green) found.green = match[2]
    else if (match[1] === "color3" && !found.yellow) found.yellow = match[2]
  }
  // Status dots are semantic (grey / green / yellow / red). Ignore a
  // theme "green" that is actually gold, which several Omarchy themes do.
  if (!isGreenish(found.green)) found.green = ""
  if (!isYellowish(found.yellow)) found.yellow = ""
  return found
}

function formatPercent(value) {
  if (value === null || value === undefined || value === "") return "—"
  var n = Number(value)
  if (!isFinite(n)) return "—"
  return String(Math.trunc(n))
}

function formatTemp(value) {
  if (value === null || value === undefined || value === "") return "—"
  var n = Number(value)
  if (!isFinite(n)) return "—"
  return String(Math.trunc(n)) + "°"
}

function formatWindow(seconds) {
  var n = Math.max(1, Math.round(Number(seconds) || 0))
  if (n < 90) return n + "s"
  if (n < 90 * 60) {
    var mins = n / 60
    return (Math.abs(mins - Math.round(mins)) < 0.05 ? String(Math.round(mins)) : mins.toFixed(1)) + "m"
  }
  if (n < 36 * HOUR_SEC) {
    var hours = n / HOUR_SEC
    return (Math.abs(hours - Math.round(hours)) < 0.05 ? String(Math.round(hours)) : hours.toFixed(1)) + "h"
  }
  var days = n / DAY_SEC
  return (Math.abs(days - Math.round(days)) < 0.05 ? String(Math.round(days)) : days.toFixed(1)) + "d"
}

function formatTick(ts, windowSec) {
  var date = new Date(Number(ts) * 1000)
  if (!isFinite(date.getTime())) return ""
  var hh = ("0" + date.getHours()).slice(-2)
  var mm = ("0" + date.getMinutes()).slice(-2)
  if (windowSec >= 18 * HOUR_SEC) return formatDateTime(ts, false)
  if (windowSec < 5 * 60) {
    var ss = ("0" + date.getSeconds()).slice(-2)
    return hh + ":" + mm + ":" + ss
  }
  return hh + ":" + mm
}

function formatDateTime(ts, withSeconds) {
  var date = new Date(Number(ts) * 1000)
  if (!isFinite(date.getTime())) return ""
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  var hh = ("0" + date.getHours()).slice(-2)
  var mm = ("0" + date.getMinutes()).slice(-2)
  var time = hh + ":" + mm
  if (withSeconds) time += ":" + ("0" + date.getSeconds()).slice(-2)
  return months[date.getMonth()] + " " + date.getDate() + "  " + time
}

function formatHoverTick(ts, windowSec) {
  return formatDateTime(ts, Number(windowSec) < 5 * 60)
}

function sameLocalDay(a, b) {
  var da = new Date(Number(a) * 1000)
  var db = new Date(Number(b) * 1000)
  if (!isFinite(da.getTime()) || !isFinite(db.getTime())) return false
  return da.getFullYear() === db.getFullYear() && da.getMonth() === db.getMonth() && da.getDate() === db.getDate()
}

function formatAxisTick(ts, windowStart, windowEnd, prevTs) {
  var span = Number(windowEnd) - Number(windowStart)
  var wantDate = span >= 18 * HOUR_SEC || !sameLocalDay(windowStart, windowEnd)
  var dayChanged = !isFinite(Number(prevTs)) || !sameLocalDay(prevTs, ts)
  if (wantDate && dayChanged) return formatDateTime(ts, false)
  return formatTick(ts, span)
}

function alignTick(ts, step) {
  var t = Number(ts)
  if (!isFinite(t) || !isFinite(Number(step)) || step <= 0) return t
  if (step >= DAY_SEC) {
    var day = new Date(t * 1000)
    day.setHours(0, 0, 0, 0)
    if (day.getTime() / 1000 < t) day.setDate(day.getDate() + 1)
    return day.getTime() / 1000
  }
  if (step >= HOUR_SEC) {
    var hour = new Date(t * 1000)
    hour.setMinutes(0, 0, 0)
    var hours = step / HOUR_SEC
    var snapped = Math.ceil(hour.getHours() / hours) * hours
    if (snapped >= 24) {
      hour.setDate(hour.getDate() + 1)
      hour.setHours(0, 0, 0, 0)
      return hour.getTime() / 1000
    }
    hour.setHours(snapped)
    if (hour.getTime() / 1000 < t) hour.setHours(hour.getHours() + hours)
    return hour.getTime() / 1000
  }
  return Math.ceil(t / step) * step
}

function axisTicks(startSec, endSec, maxTicks) {
  var start = Number(startSec)
  var end = Number(endSec)
  if (!isFinite(start) || !isFinite(end) || end <= start) return []
  var count = Math.max(3, Math.min(7, Math.round(Number(maxTicks) || 5)))
  var span = end - start
  var steps = [60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 14400, 21600, 43200, 86400]
  var target = span / Math.max(1, count - 1)
  var step = steps[steps.length - 1]
  for (var i = 0; i < steps.length; i++) {
    if (steps[i] >= target) { step = steps[i]; break }
  }

  var ticks = [start]
  var t = alignTick(start, step)
  if (t - start < step * 0.35) t += step
  while (t < end - step * 0.35) {
    ticks.push(t)
    t += step
    if (ticks.length > 10) break
  }
  if (end - ticks[ticks.length - 1] > step * 0.35) ticks.push(end)
  else ticks[ticks.length - 1] = end
  return ticks
}

function zoomWindow(startSec, endSec, factor, anchorSec, now, dbFirst) {
  var start = Number(startSec)
  var end = Number(endSec)
  if (!isFinite(start) || !isFinite(end) || end <= start) {
    end = Number(now) || nowSec()
    start = end - DEFAULT_WINDOW_SEC
  }
  var span = clamp((end - start) * Number(factor), MIN_WINDOW_SEC, MAX_WINDOW_SEC)
  var anchor = isFinite(Number(anchorSec)) ? Number(anchorSec) : (start + end) / 2
  var frac = clamp((anchor - start) / (end - start), 0, 1)
  var nextStart = anchor - span * frac
  var nextEnd = nextStart + span
  return clampWindow(nextStart, nextEnd, now, dbFirst)
}

function panWindow(startSec, endSec, deltaSec, now, dbFirst) {
  return clampWindow(Number(startSec) + Number(deltaSec), Number(endSec) + Number(deltaSec), now, dbFirst)
}

function liveWindow(durationSec, now) {
  var end = Number(now) || nowSec()
  var span = clamp(durationSec, MIN_WINDOW_SEC, MAX_WINDOW_SEC)
  return { start: end - span, end: end, live: true }
}

function clampWindow(startSec, endSec, now, dbFirst) {
  var end = Number(endSec)
  var start = Number(startSec)
  var latest = Number(now) || nowSec()
  if (!isFinite(end)) end = latest
  if (!isFinite(start) || end <= start) start = end - DEFAULT_WINDOW_SEC
  var span = clamp(end - start, MIN_WINDOW_SEC, MAX_WINDOW_SEC)
  if (end > latest) {
    end = latest
    start = end - span
  }
  if (isFinite(Number(dbFirst)) && Number(dbFirst) > 0 && start < Number(dbFirst)) {
    start = Number(dbFirst)
    end = Math.min(latest, start + span)
    if (end - start < MIN_WINDOW_SEC) end = Math.min(latest, start + MIN_WINDOW_SEC)
  }
  return {
    start: start,
    end: end,
    live: (latest - end) < 3
  }
}

// How far (seconds) a hover may sit from a real sample and still show that
// sample's value. Wide windows downsample to sparse points, so the
// tolerance scales with the sampling interval; the cap keeps a long outage
// (hours of nothing) a gap no matter how sparse the surrounding data is.
var MIN_GAP_SEC = 60
var MAX_FILL_SEC = 40 * 60
var GAP_SPACING_FACTOR = 3

function gapThresholdSec(points) {
  var n = points.length
  if (n < 2) return MIN_GAP_SEC
  var sum = 0
  var count = 0
  for (var i = 1; i < n; i++) {
    var d = Number(points[i].t) - Number(points[i - 1].t)
    if (d > 0) {
      sum += d
      count++
    }
  }
  if (!count) return MIN_GAP_SEC
  var threshold = GAP_SPACING_FACTOR * (sum / count)
  return Math.max(MIN_GAP_SEC, Math.min(MAX_FILL_SEC, threshold))
}

// Hover value at time t. Never interpolates across missing data: within
// the gap tolerance it fills forward/back from the nearest real sample;
// beyond it (e.g. a Netdata outage window) it returns null, so the chart
// shows no dot and the tooltip reads "—" instead of a fabricated value.
function valueAtTime(points, t) {
  if (!points || !points.length || !isFinite(Number(t))) return null
  var ts = Number(t)
  var threshold = gapThresholdSec(points)
  var prev = null
  var next = null
  for (var i = 0; i < points.length; i++) {
    var p = points[i]
    if (!presentNumber(p.v)) continue
    if (p.t <= ts) {
      prev = p
    } else {
      next = p
      break
    }
  }
  if (prev && ts - Number(prev.t) <= threshold) return Number(prev.v)
  if (next && Number(next.t) - ts <= threshold) return Number(next.v)
  return null
}

function historyPointsForWidth(widthPx) {
  var w = Number(widthPx)
  if (!isFinite(w) || w < 80) return 120
  return Math.max(60, Math.min(400, Math.round(w / 2)))
}
