import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Polls a remote Netdata v3 endpoint for GPU utilization plus three
// companion metrics (temperature, memory, power). Created by the plugin
// service registry (one per host+charts group) so dual-monitor pills
// share connected/polling state. The panel asks it for a history window
// on demand. Each companion resolves to its own context (see
// Model.configuredTempQuery / configuredMemQuery / configuredPowerQuery);
// memory requests only the "used" dimension. A failed companion poll never
// stops the widget.
Item {
  id: root
  width: 0
  height: 0
  visible: false

  property var settings: ({})

  property bool connected: false
  property var currentValue: null
  property var points: []
  property string lastError: ""
  property string nodeName: ""
  property string chartTitle: Model.defaultTitle()
  property string units: "%"
  property real dbFirst: 0
  property real dbLast: 0
  property real lastSampleAt: 0
  property bool polling: true
  property int failCount: 0
  // When the current failure streak began (ms epoch); 0 = not in a streak.
  property real retryStartedAt: 0
  property bool countedThisPoll: false
  property bool latestAborted: false
  property bool historyAborted: false
  property bool latestSawData: false
  property bool historySawData: false

  // Per-companion transient flags (latest + history runs).
  property bool tempAborted: false
  property bool tempHistoryAborted: false
  property bool tempSawData: false
  property bool tempHistorySawData: false
  property bool memAborted: false
  property bool memHistoryAborted: false
  property bool memSawData: false
  property bool memHistorySawData: false
  property bool powerAborted: false
  property bool powerHistoryAborted: false
  property bool powerSawData: false
  property bool powerHistorySawData: false

  // Companion state: value, points, split-aligned series, units, title.
  property var tempValue: null
  property var tempPoints: []
  property var tempSeries: []
  property var splitTempValues: []
  property string tempUnits: "\u00B0C"
  property string tempTitle: Model.defaultTempTitle()
  property var memValue: null
  property var memPoints: []
  property var memSeries: []
  property var splitMemValues: []
  property string memUnits: ""
  property string memTitle: Model.defaultMemTitle()
  property var powerValue: null
  property var powerPoints: []
  property var powerSeries: []
  property var splitPowerValues: []
  property string powerUnits: ""
  property string powerTitle: Model.defaultPowerTitle()

  property var series: []
  property var splitValues: []

  readonly property string hostRaw: Model.configuredHost(settings)
  readonly property string contextId: Model.configuredContext(settings)
  readonly property var tempQuery: Model.configuredTempQuery(settings)
  readonly property string tempContextId: tempQuery.context
  readonly property var memQuery: Model.configuredMemQuery(settings)
  readonly property string memContextId: memQuery.context
  readonly property var powerQuery: Model.configuredPowerQuery(settings)
  readonly property string powerContextId: powerQuery.context
  readonly property string hostLabel: Model.hostLabel(hostRaw)
  readonly property int refreshMs: Model.configuredRefreshMs(settings)
  readonly property int retryAttempts: Model.configuredRetryAttempts(settings)
  readonly property int retryWindowMs: Model.configuredRetryWindowMs(settings)
  readonly property bool splitEnabled: Model.configuredSplit(settings)
  readonly property string status: Model.statusKey(connected, currentValue)

  signal seriesUpdated()

  function togglePolling() {
    polling = !polling
    resetFailureState()
    if (polling) refreshLatest()
  }

  // A success, a manual toggle, or a host/context change all start a fresh
  // retry window.
  function resetFailureState() {
    failCount = 0
    retryStartedAt = 0
  }

  function abortIfTooLarge(proc, data, maxBytes) {
    if (!Model.collectorOverLimit(data, maxBytes)) return false
    if (proc.running) proc.running = false
    return true
  }

  function wrapSingle(points) {
    return [{ name: "", key: "", points: points }]
  }

  function parseChartSeries(payload) {
    if (splitEnabled) return Model.parseSeriesSplit(payload)
    return wrapSingle(Model.parseSeries(payload))
  }

  // Companions reuse the primary's split parsing; when the primary is
  // split, align this companion's columns to the primary's GPU order so
  // GPU1 lines up across all charts.
  function parseCompanionSeries(payload) {
    var parsed = parseChartSeries(payload)
    if (series.length) return Model.alignSeriesByKey(series, parsed)
    return parsed
  }

  function lastRow(parsed) {
    if (!parsed || !parsed.length || !parsed[0].points || !parsed[0].points.length)
      return null
    var lastT = parsed[0].points[parsed[0].points.length - 1].t
    var values = []
    for (var i = 0; i < parsed.length; i++) {
      var pts = parsed[i].points
      values.push(pts && pts.length ? pts[pts.length - 1].v : null)
    }
    return { t: lastT, values: values }
  }

  function replaceWithLastSample(parsed) {
    var last = lastRow(parsed)
    if (!last) return []
    var next = []
    for (var i = 0; i < parsed.length; i++) {
      next.push({
        name: parsed[i].name,
        key: parsed[i].key,
        points: [{ t: last.t, v: last.values[i] }]
      })
    }
    return next
  }

  function adoptSeries(next) {
    series = next
    points = next.length ? next[0].points : []
    splitValues = Model.latestValuePerSeries(next)
    if (tempSeries.length) adoptTempSeries(tempSeries)
    if (memSeries.length) adoptMemSeries(memSeries)
    if (powerSeries.length) adoptPowerSeries(powerSeries)
  }

  function adoptTempSeries(next) {
    var aligned = series.length ? Model.alignSeriesByKey(series, next) : next
    tempSeries = aligned
    tempPoints = aligned.length ? aligned[0].points : []
    splitTempValues = Model.latestValuePerSeries(aligned)
  }

  function adoptMemSeries(next) {
    var aligned = series.length ? Model.alignSeriesByKey(series, next) : next
    memSeries = aligned
    memPoints = aligned.length ? aligned[0].points : []
    splitMemValues = Model.latestValuePerSeries(aligned)
  }

  function adoptPowerSeries(next) {
    var aligned = series.length ? Model.alignSeriesByKey(series, next) : next
    powerSeries = aligned
    powerPoints = aligned.length ? aligned[0].points : []
    splitPowerValues = Model.latestValuePerSeries(aligned)
  }

  function clearSeriesState() {
    series = []
    points = []
    splitValues = []
    currentValue = null
    clearCompanionState()
  }

  function clearCompanionState() {
    tempValue = null; tempPoints = []; tempSeries = []; splitTempValues = []
    memValue = null; memPoints = []; memSeries = []; splitMemValues = []
    powerValue = null; powerPoints = []; powerSeries = []; splitPowerValues = []
  }

  function refreshLatest() {
    if (latestProc.running) {
      refreshCompanions()
      return
    }
    countedThisPoll = false
    latestAborted = false
    latestSawData = false
    latestProc.command = ["curl", "-fsS", "--max-time", "4", "--max-filesize", String(Model.maxLatestResponseBytes()), Model.latestUrl(hostRaw, contextId, Model.queryExtra(null, splitEnabled))]
    latestProc.running = true
    refreshCompanions()
  }

  // Kick a latest fetch for every companion that has a context. A missing
  // context (e.g. a GPU the vendor module doesn't expose) just leaves the
  // metric empty.
  function refreshCompanions() {
    refreshTemp()
    refreshMem()
    refreshPower()
  }

  function refreshTemp() {
    if (!tempContextId) { tempValue = null; return }
    if (tempProc.running) return
    tempAborted = false
    tempSawData = false
    tempProc.command = ["curl", "-fsS", "--max-time", "4", "--max-filesize", String(Model.maxLatestResponseBytes()), Model.latestUrl(hostRaw, tempContextId, Model.queryExtra(tempQuery, splitEnabled))]
    tempProc.running = true
  }

  function refreshMem() {
    if (!memContextId) { memValue = null; return }
    if (memProc.running) return
    memAborted = false
    memSawData = false
    memProc.command = ["curl", "-fsS", "--max-time", "4", "--max-filesize", String(Model.maxLatestResponseBytes()), Model.latestUrl(hostRaw, memContextId, Model.queryExtra(memQuery, splitEnabled))]
    memProc.running = true
  }

  function refreshPower() {
    if (!powerContextId) { powerValue = null; return }
    if (powerProc.running) return
    powerAborted = false
    powerSawData = false
    powerProc.command = ["curl", "-fsS", "--max-time", "4", "--max-filesize", String(Model.maxLatestResponseBytes()), Model.latestUrl(hostRaw, powerContextId, Model.queryExtra(powerQuery, splitEnabled))]
    powerProc.running = true
  }

  function refreshHistory(startSec, endSec, pointsWanted) {
    if (historyProc.running) {
      pendingHistory = { start: startSec, end: endSec, points: pointsWanted }
    } else {
      pendingHistory = null
      historyAborted = false
      historySawData = false
      historyProc.command = ["curl", "-fsS", "--max-time", "6", "--max-filesize", String(Model.maxHistoryResponseBytes()), Model.historyUrl(hostRaw, contextId, startSec, endSec, pointsWanted, Model.queryExtra(null, splitEnabled))]
      historyProc.running = true
    }
    refreshCompanionHistory(startSec, endSec, pointsWanted)
  }

  function refreshCompanionHistory(startSec, endSec, pointsWanted) {
    refreshTempHistory(startSec, endSec, pointsWanted)
    refreshMemHistory(startSec, endSec, pointsWanted)
    refreshPowerHistory(startSec, endSec, pointsWanted)
  }

  function refreshTempHistory(startSec, endSec, pointsWanted) {
    if (!tempContextId) { tempPoints = []; return }
    if (tempHistoryProc.running) { pendingTempHistory = { start: startSec, end: endSec, points: pointsWanted }; return }
    pendingTempHistory = null
    tempHistoryAborted = false
    tempHistorySawData = false
    tempHistoryProc.command = ["curl", "-fsS", "--max-time", "6", "--max-filesize", String(Model.maxHistoryResponseBytes()), Model.historyUrl(hostRaw, tempContextId, startSec, endSec, pointsWanted, Model.queryExtra(tempQuery, splitEnabled))]
    tempHistoryProc.running = true
  }

  function refreshMemHistory(startSec, endSec, pointsWanted) {
    if (!memContextId) { memPoints = []; return }
    if (memHistoryProc.running) { pendingMemHistory = { start: startSec, end: endSec, points: pointsWanted }; return }
    pendingMemHistory = null
    memHistoryAborted = false
    memHistorySawData = false
    memHistoryProc.command = ["curl", "-fsS", "--max-time", "6", "--max-filesize", String(Model.maxHistoryResponseBytes()), Model.historyUrl(hostRaw, memContextId, startSec, endSec, pointsWanted, Model.queryExtra(memQuery, splitEnabled))]
    memHistoryProc.running = true
  }

  function refreshPowerHistory(startSec, endSec, pointsWanted) {
    if (!powerContextId) { powerPoints = []; return }
    if (powerHistoryProc.running) { pendingPowerHistory = { start: startSec, end: endSec, points: pointsWanted }; return }
    pendingPowerHistory = null
    powerHistoryAborted = false
    powerHistorySawData = false
    powerHistoryProc.command = ["curl", "-fsS", "--max-time", "6", "--max-filesize", String(Model.maxHistoryResponseBytes()), Model.historyUrl(hostRaw, powerContextId, startSec, endSec, pointsWanted, Model.queryExtra(powerQuery, splitEnabled))]
    powerHistoryProc.running = true
  }

  function applyLatest(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxLatestResponseBytes())) {
      markDisconnected("latest response too large")
      return
    }
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result) {
      markDisconnected("empty latest payload")
      return
    }
    var parsed = parseChartSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    if (value === null) {
      markDisconnected("no latest value")
      return
    }
    connected = true
    lastError = ""
    resetFailureState()
    currentValue = value
    splitValues = values
    if (meta.nodeName) nodeName = meta.nodeName
    if (meta.title) chartTitle = meta.title
    if (meta.units) units = meta.units
    if (isFinite(meta.dbFirst)) dbFirst = meta.dbFirst
    if (isFinite(meta.dbLast)) dbLast = meta.dbLast
    var last = lastRow(parsed)
    if (last) {
      lastSampleAt = last.t
      var next = series.length !== parsed.length
        ? replaceWithLastSample(parsed)
        : Model.mergeSeriesPoint(series, last.t, last.values)
      adoptSeries(Model.pruneSeries(next, last.t))
      splitValues = values
    }
    seriesUpdated()
  }

  // Latest companion poll: merge the newest sample into the running series
  // (or replace it when the GPU count changed). A failed/empty poll leaves
  // the previous samples intact.
  function applyTemp(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxLatestResponseBytes())) { tempValue = null; return }
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result) { tempValue = null; return }
    var parsed = parseCompanionSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    if (value !== null) tempValue = value
    splitTempValues = values
    if (meta.units) tempUnits = meta.units
    var last = lastRow(parsed)
    if (last) {
      var next = tempSeries.length !== parsed.length
        ? replaceWithLastSample(parsed)
        : Model.mergeSeriesPoint(tempSeries, last.t, last.values)
      adoptTempSeries(Model.pruneSeries(next, last.t))
      splitTempValues = values
    }
  }

  function applyMem(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxLatestResponseBytes())) { memValue = null; return }
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result) { memValue = null; return }
    var parsed = parseCompanionSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    if (value !== null) memValue = value
    splitMemValues = values
    if (meta.units) memUnits = meta.units
    var last = lastRow(parsed)
    if (last) {
      var next = memSeries.length !== parsed.length
        ? replaceWithLastSample(parsed)
        : Model.mergeSeriesPoint(memSeries, last.t, last.values)
      adoptMemSeries(Model.pruneSeries(next, last.t))
      splitMemValues = values
    }
  }

  function applyPower(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxLatestResponseBytes())) { powerValue = null; return }
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result) { powerValue = null; return }
    var parsed = parseCompanionSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    if (value !== null) powerValue = value
    splitPowerValues = values
    if (meta.units) powerUnits = meta.units
    var last = lastRow(parsed)
    if (last) {
      var next = powerSeries.length !== parsed.length
        ? replaceWithLastSample(parsed)
        : Model.mergeSeriesPoint(powerSeries, last.t, last.values)
      adoptPowerSeries(Model.pruneSeries(next, last.t))
      splitPowerValues = values
    }
  }

  // History companion fetch: replace the window with the parsed range.
  function applyTempHistory(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxHistoryResponseBytes())) return
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result) return
    var parsed = parseCompanionSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    if (value !== null) tempValue = value
    splitTempValues = values
    if (meta.units) tempUnits = meta.units
    adoptTempSeries(Model.pruneSeries(parsed))
  }

  function applyMemHistory(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxHistoryResponseBytes())) return
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result) return
    var parsed = parseCompanionSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    if (value !== null) memValue = value
    splitMemValues = values
    if (meta.units) memUnits = meta.units
    adoptMemSeries(Model.pruneSeries(parsed))
  }

  function applyPowerHistory(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxHistoryResponseBytes())) return
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result) return
    var parsed = parseCompanionSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    if (value !== null) powerValue = value
    splitPowerValues = values
    if (meta.units) powerUnits = meta.units
    adoptPowerSeries(Model.pruneSeries(parsed))
  }

  function applyHistory(raw) {
    if (!Model.responseWithinLimit(raw, Model.maxHistoryResponseBytes())) {
      lastError = "history response too large"
      return
    }
    var payload = Model.parsePayload(raw)
    if (!payload || !payload.result) {
      lastError = "empty history payload"
      return
    }
    var parsed = parseChartSeries(payload)
    var meta = Model.parseMeta(payload)
    var values = Model.latestValuePerSeries(parsed)
    var value = Model.maxOf(values)
    lastError = ""
    if (value !== null) {
      connected = true
      resetFailureState()
      currentValue = value
    }
    splitValues = values
    if (meta.nodeName) nodeName = meta.nodeName
    if (meta.title) chartTitle = meta.title
    if (meta.units) units = meta.units
    if (isFinite(meta.dbFirst)) dbFirst = meta.dbFirst
    if (isFinite(meta.dbLast)) dbLast = meta.dbLast
    adoptSeries(Model.pruneSeries(parsed))
    if (parsed.length && parsed[0].points && parsed[0].points.length)
      lastSampleAt = parsed[0].points[parsed[0].points.length - 1].t
    seriesUpdated()
  }

  function markDisconnected(reason) {
    connected = false
    currentValue = null
    lastError = reason || "unreachable"
    if (!polling || countedThisPoll) return
    countedThisPoll = true
    // Backoff stretches the cadence as failures pile up (doubling after
    // retryAttempts, capped at the liveness probe). Any success resets
    // failCount below, so the window only runs for one continuous streak.
    if (failCount === 0) retryStartedAt = Date.now()
    failCount += 1
    if (retryStartedAt && retryWindowMs > 0
        && Date.now() - retryStartedAt >= retryWindowMs) {
      // Gave up: stay stopped until the user flips the switch again.
      polling = false
    }
  }

  property var pendingHistory: null
  property var pendingTempHistory: null
  property var pendingMemHistory: null
  property var pendingPowerHistory: null

  onHostRawChanged: {
    clearSeriesState()
    connected = false
    lastError = ""
    resetFailureState()
    chartTitle = Model.defaultTitle()
    tempTitle = Model.defaultTempTitle()
    memTitle = Model.defaultMemTitle()
    powerTitle = Model.defaultPowerTitle()
    refreshLatest()
  }

  onContextIdChanged: {
    clearSeriesState()
    connected = false
    resetFailureState()
    chartTitle = Model.defaultTitle()
    refreshLatest()
  }

  onTempContextIdChanged: {
    tempValue = null; tempPoints = []; tempSeries = []; splitTempValues = []
    if (polling) refreshTemp()
  }

  onMemContextIdChanged: {
    memValue = null; memPoints = []; memSeries = []; splitMemValues = []
    if (polling) refreshMem()
  }

  onPowerContextIdChanged: {
    powerValue = null; powerPoints = []; powerSeries = []; splitPowerValues = []
    if (polling) refreshPower()
  }

  onSplitEnabledChanged: {
    clearSeriesState()
    refreshLatest()
  }

  // Changing a running Timer's interval does not restart its countdown
  // reliably, so re-arm explicitly whenever the failure count (and thus the
  // backoff interval) changes. callLater lets the `running` binding settle
  // first; failCount only changes while polling, so this cannot unpause it.
  onFailCountChanged: Qt.callLater(function() { if (root.polling) pollTimer.restart() })

  // While offline the interval stretches: base cadence for the first
  // retryAttempts failures, then doubling, capped at the liveness probe.
  Timer {
    id: pollTimer
    interval: Model.backoffMs(root.failCount, root.refreshMs, root.retryAttempts)
    running: root.polling
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshLatest()
  }

  Process {
    id: latestProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        root.latestSawData = true
        if (root.abortIfTooLarge(latestProc, data, Model.maxLatestResponseBytes()))
          root.latestAborted = true
      }
      onStreamFinished: {
        if (root.latestAborted) {
          root.markDisconnected("latest response too large")
          return
        }
        // waitForEnd:false leaves mData uncleared; do not apply a prior run.
        root.applyLatest(root.latestSawData ? text : "")
      }
    }
    onExited: function(code) {
      if (root.latestAborted) return
      if (code !== 0) root.markDisconnected("latest fetch failed")
    }
  }

  Process {
    id: tempProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        root.tempSawData = true
        if (root.abortIfTooLarge(tempProc, data, Model.maxLatestResponseBytes()))
          root.tempAborted = true
      }
      onStreamFinished: {
        if (root.tempAborted) return
        root.applyTemp(root.tempSawData ? text : "")
      }
    }
  }

  Process {
    id: memProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        root.memSawData = true
        if (root.abortIfTooLarge(memProc, data, Model.maxLatestResponseBytes()))
          root.memAborted = true
      }
      onStreamFinished: {
        if (root.memAborted) return
        root.applyMem(root.memSawData ? text : "")
      }
    }
  }

  Process {
    id: powerProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        root.powerSawData = true
        if (root.abortIfTooLarge(powerProc, data, Model.maxLatestResponseBytes()))
          root.powerAborted = true
      }
      onStreamFinished: {
        if (root.powerAborted) return
        root.applyPower(root.powerSawData ? text : "")
      }
    }
  }

  Process {
    id: historyProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        root.historySawData = true
        if (root.abortIfTooLarge(historyProc, data, Model.maxHistoryResponseBytes()))
          root.historyAborted = true
      }
      onStreamFinished: {
        if (root.historyAborted) {
          root.lastError = "history response too large"
          return
        }
        root.applyHistory(root.historySawData ? text : "")
      }
    }
    onExited: function(code) {
      if (!root.historyAborted && code !== 0) root.lastError = "history fetch failed"
      if (root.pendingHistory) {
        var req = root.pendingHistory
        root.pendingHistory = null
        Qt.callLater(function() { root.refreshHistory(req.start, req.end, req.points) })
      }
    }
  }

  Process {
    id: tempHistoryProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        root.tempHistorySawData = true
        if (root.abortIfTooLarge(tempHistoryProc, data, Model.maxHistoryResponseBytes()))
          root.tempHistoryAborted = true
      }
      onStreamFinished: {
        if (root.tempHistoryAborted) return
        root.applyTempHistory(root.tempHistorySawData ? text : "")
      }
    }
    onExited: function(code) {
      if (root.pendingTempHistory) {
        var req = root.pendingTempHistory
        root.pendingTempHistory = null
        Qt.callLater(function() { root.refreshTempHistory(req.start, req.end, req.points) })
      }
    }
  }

  Process {
    id: memHistoryProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        root.memHistorySawData = true
        if (root.abortIfTooLarge(memHistoryProc, data, Model.maxHistoryResponseBytes()))
          root.memHistoryAborted = true
      }
      onStreamFinished: {
        if (root.memHistoryAborted) return
        root.applyMemHistory(root.memHistorySawData ? text : "")
      }
    }
    onExited: function(code) {
      if (root.pendingMemHistory) {
        var req = root.pendingMemHistory
        root.pendingMemHistory = null
        Qt.callLater(function() { root.refreshMemHistory(req.start, req.end, req.points) })
      }
    }
  }

  Process {
    id: powerHistoryProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        root.powerHistorySawData = true
        if (root.abortIfTooLarge(powerHistoryProc, data, Model.maxHistoryResponseBytes()))
          root.powerHistoryAborted = true
      }
      onStreamFinished: {
        if (root.powerHistoryAborted) return
        root.applyPowerHistory(root.powerHistorySawData ? text : "")
      }
    }
    onExited: function(code) {
      if (root.pendingPowerHistory) {
        var req = root.pendingPowerHistory
        root.pendingPowerHistory = null
        Qt.callLater(function() { root.refreshPowerHistory(req.start, req.end, req.points) })
      }
    }
  }
}
