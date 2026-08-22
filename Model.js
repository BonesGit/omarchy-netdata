.pragma library

// Netdata v3 helpers for the bar widget. Keep this file free of QML
// objects so Panel, Service, and the chart can share the same parsing.

var DEFAULT_HOST = "localhost"
var DEFAULT_CONTEXT = "nvidia_smi.gpu_utilization"
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

function defaultHost() { return DEFAULT_HOST }
function defaultWindowSec() { return DEFAULT_WINDOW_SEC }
function maxWindowSec() { return MAX_WINDOW_SEC }
function maxLatestResponseBytes() { return MAX_LATEST_RESPONSE_BYTES }
function maxHistoryResponseBytes() { return MAX_HISTORY_RESPONSE_BYTES }

function responseWithinLimit(raw, maxBytes) {
  var limit = Number(maxBytes)
  if (!isFinite(limit) || limit <= 0) return true
  return String(raw || "").length <= limit
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

function configuredContext(settings) {
  var raw = settings && settings.context !== undefined && settings.context !== null ? settings.context : DEFAULT_CONTEXT
  return String(raw || DEFAULT_CONTEXT).replace(/^\s+|\s+$/g, "") || DEFAULT_CONTEXT
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
    label: host
  }
}

function hostLabel(raw) {
  return parseHost(raw).label
}

function dataUrl(rawHost, context, after, before, points) {
  var parsed = parseHost(rawHost)
  var ctx = encodeURIComponent(context || DEFAULT_CONTEXT)
  var url = parsed.origin + "/api/v3/data?contexts=" + ctx
    + "&after=" + encodeURIComponent(String(after))
    + "&points=" + encodeURIComponent(String(Math.max(2, Math.round(points || 120))))
    + "&group=average&format=json"
  if (before !== undefined && before !== null && before !== "")
    url += "&before=" + encodeURIComponent(String(before))
  return url
}

function latestUrl(rawHost, context) {
  return dataUrl(rawHost, context, -60, 0, 12)
}

function historyUrl(rawHost, context, startSec, endSec, points) {
  return dataUrl(rawHost, context, Math.floor(startSec), Math.floor(endSec), points)
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

function parseMeta(payload) {
  var view = payload && payload.view ? payload.view : {}
  var db = payload && payload.db ? payload.db : {}
  var summary = payload && payload.summary ? payload.summary : {}
  var node = summary.nodes && summary.nodes[0] ? summary.nodes[0] : null
  return {
    title: view.title || "GPU utilization",
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

// Drop samples older than the chart's max window so live polling cannot
// grow the series without bound while the popup stays closed.
function prunePoints(points, newestSec) {
  if (!points || !points.length) return []
  var newest = Number(newestSec)
  if (!isFinite(newest) && points.length)
    newest = Number(points[points.length - 1].t)
  if (!isFinite(newest)) return points
  var cutoff = newest - MAX_WINDOW_SEC
  var i = 0
  while (i < points.length && Number(points[i].t) < cutoff) i++
  if (i === 0) return points
  return points.slice(i)
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
  var n = Number(value)
  if (!isFinite(n)) return "—"
  if (Math.abs(n - Math.round(n)) < 0.05) return String(Math.round(n))
  return n.toFixed(1)
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

function interpolate(points, t) {
  if (!points || !points.length || !isFinite(Number(t))) return null
  var ts = Number(t)
  var prev = null
  for (var i = 0; i < points.length; i++) {
    var p = points[i]
    if (!isFinite(Number(p.v))) continue
    if (p.t === ts) return Number(p.v)
    if (p.t > ts) {
      if (!prev) return Number(p.v)
      var span = p.t - prev.t
      if (span <= 0) return Number(p.v)
      var frac = (ts - prev.t) / span
      return Number(prev.v) + (Number(p.v) - Number(prev.v)) * frac
    }
    prev = p
  }
  return prev ? Number(prev.v) : null
}

function historyPointsForWidth(widthPx) {
  var w = Number(widthPx)
  if (!isFinite(w) || w < 80) return 120
  return Math.max(60, Math.min(400, Math.round(w / 2)))
}
