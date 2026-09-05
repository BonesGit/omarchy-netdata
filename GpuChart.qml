import QtQuick
import qs.Commons
import "Model.js" as Model

// Interactive GPU utilization chart. Wheel zooms the time window around
// the cursor; drag pans along X. Painting stays on a Canvas so the rest
// of the panel can keep using stock Omarchy surfaces.
Item {
  id: root

  property var points: []
  property var series: []
  property real windowStart: 0
  property real windowEnd: 0
  property color lineColor: Color.accent
  property color secondaryColor: Color.urgent
  property color gridColor: Color.muted
  property color textColor: Color.foreground
  property color crosshairColor: Color.foreground
  property string fontFamily: Style.font.family
  property bool live: true
  property bool autoScale: false
  property bool compact: false
  property bool temperature: false
  // Non-empty units (e.g. "B", "Watts") switch the hover tooltip from the
  // percent formatter to the unit-aware metric formatter.
  property var metricUnits: ""
  property real yMin: 0
  property real yMax: 100

  readonly property real windowSpan: Math.max(1, windowEnd - windowStart)
  readonly property var plotPoints: Model.visiblePoints(points, windowStart, windowEnd)
  readonly property var plotSeries: {
    var out = []
    var list = series
    if (!list || !list.length) return out
    for (var i = 0; i < list.length; i++)
      out.push(Model.visiblePoints(list[i].points, windowStart, windowEnd))
    return out
  }
  readonly property bool useSeries: !!(series && series.length)
  readonly property real axisBand: compact ? Style.space(4) : Style.space(18)
  readonly property real plotHeight: Math.max(1, height - axisBand)
  readonly property var valueRange: {
    if (!autoScale) return { min: yMin, max: yMax }
    var lo = Infinity
    var hi = -Infinity
    var lists = useSeries ? plotSeries : [plotPoints]
    for (var s = 0; s < lists.length; s++) {
      var pts = lists[s] || []
      for (var i = 0; i < pts.length; i++) {
        if (pts[i].v === null || pts[i].v === undefined || pts[i].v === "") continue
        var n = Number(pts[i].v)
        if (!isFinite(n)) continue
        if (n < lo) lo = n
        if (n > hi) hi = n
      }
    }
    if (!isFinite(lo)) return { min: yMin, max: yMax }
    if (lo === hi) {
      lo = Math.max(0, lo - 5)
      hi = hi + 5
    } else {
      var pad = Math.max(2, (hi - lo) * 0.15)
      lo -= pad
      hi += pad
    }
    return { min: lo, max: hi }
  }

  property real hoverX: -1
  property real hoverT: NaN
  property var hoverV: null
  property var hoverValues: []
  // Pointer is on the chart but every series has no data there (a gap).
  property bool hoverGap: false
  property real wheelAcc: 0

  signal zoomRequested(real factor, real anchorSec)
  signal panRequested(real deltaSec)
  // NaN means the pointer left this chart. Panel mirrors finite t onto the other chart.
  signal hoverMoved(real t)
  property bool syncHover: false
  readonly property bool hoverActive: mouse.containsMouse || mouse.dragging

  function xForTime(t) {
    return ((t - windowStart) / windowSpan) * canvas.width
  }

  function timeForX(x) {
    return windowStart + (x / Math.max(1, canvas.width)) * windowSpan
  }

  function yForValue(v) {
    var n = Number(v)
    if (!isFinite(n)) return canvas.height
    var lo = Number(valueRange.min)
    var hi = Number(valueRange.max)
    var span = hi - lo
    if (!isFinite(span) || span <= 0) span = 1
    var t = (n - lo) / span
    t = Math.max(0, Math.min(1, t))
    return canvas.height - axisBand - t * plotHeight
  }

  function yTicks() {
    if (!autoScale) return [0, 25, 50, 75, 100]
    var lo = Number(valueRange.min)
    var hi = Number(valueRange.max)
    if (!isFinite(lo) || !isFinite(hi)) return []
    if (compact) return [lo, hi]
    return [lo, (lo + hi) / 2, hi]
  }

  function strokeColor(index) {
    if (index === 0) return root.lineColor
    if (index === 1) return root.secondaryColor
    return Util.alpha(Color.foreground, 0.5)
  }

  function finiteValue(v) {
    if (v === null || v === undefined || v === "") return false
    return isFinite(Number(v))
  }

  function formatHoverValue(v) {
    if (temperature) return Model.formatTemp(v)
    if (metricUnits !== "") return Model.formatMetric(v, metricUnits)
    if (!finiteValue(v)) return "—"
    return Model.formatPercent(v) + "%"
  }

  function hoverText() {
    if (useSeries && series.length > 1) {
      var parts = []
      for (var i = 0; i < series.length; i++) {
        var name = series[i].name || ("GPU" + (i + 1))
        parts.push(name + " " + formatHoverValue(hoverValues[i]))
      }
      return parts.join(" · ") + "  " + Model.formatHoverTick(hoverT, windowSpan)
    }
    var value = formatHoverValue(hoverV)
    return value + "  " + Model.formatHoverTick(hoverT, windowSpan)
  }

  function setHoverTime(t) {
    if (!isFinite(t)) {
      hoverX = -1
      hoverT = NaN
      hoverV = null
      hoverValues = []
      hoverGap = false
      canvas.requestPaint()
      return
    }
    hoverT = t
    hoverX = xForTime(t)
    var lists = useSeries ? plotSeries : [plotPoints]
    var vals = []
    var first = null
    for (var i = 0; i < lists.length; i++) {
      var v = Model.valueAtTime(lists[i], hoverT)
      vals.push(v)
      if (first === null && finiteValue(v)) first = v
    }
    hoverValues = vals
    hoverV = first
    hoverGap = !finiteValue(first)
    canvas.requestPaint()
  }

  function applyHoverTime(t) {
    setHoverTime(t)
  }

  function clearHover() {
    setHoverTime(NaN)
  }

  function updateHover(x) {
    var lists = useSeries ? plotSeries : [plotPoints]
    var empty = true
    for (var e = 0; e < lists.length; e++) {
      if (lists[e] && lists[e].length) { empty = false; break }
    }
    if (x < 0 || x > width || empty) {
      if (syncHover) {
        hoverMoved(NaN)
      } else {
        clearHover()
      }
      return
    }
    hoverX = x
    hoverT = timeForX(x)
    var vals = []
    var first = null
    for (var i = 0; i < lists.length; i++) {
      var v = Model.valueAtTime(lists[i], hoverT)
      vals.push(v)
      if (first === null && finiteValue(v)) first = v
    }
    hoverValues = vals
    hoverV = first
    hoverGap = !finiteValue(first)
    canvas.requestPaint()
    hoverMoved(hoverT)
  }

  function refreshHover() {
    if (mouse.pressed || mouse.containsMouse)
      updateHover(mouse.mouseX)
    else if (isFinite(hoverT) && hoverX >= 0)
      setHoverTime(hoverT)
    else
      canvas.requestPaint()
  }

  onPointsChanged: refreshHover()
  onSeriesChanged: refreshHover()
  onWindowStartChanged: refreshHover()
  onWindowEndChanged: refreshHover()
  onAutoScaleChanged: canvas.requestPaint()
  onCompactChanged: canvas.requestPaint()
  onLineColorChanged: canvas.requestPaint()
  onSecondaryColorChanged: canvas.requestPaint()
  onGridColorChanged: canvas.requestPaint()
  onTextColorChanged: canvas.requestPaint()
  onWidthChanged: refreshHover()
  onHeightChanged: refreshHover()

  Canvas {
    id: canvas
    anchors.fill: parent

    onPaint: {
      var ctx = getContext("2d")
      var w = width
      var h = height
      ctx.reset()
      ctx.clearRect(0, 0, w, h)
      if (w < 2 || h < 2) return

      ctx.lineWidth = 1
      ctx.strokeStyle = Util.alpha(root.gridColor, 0.28).toString()
      ctx.fillStyle = Util.alpha(root.textColor, 0.45).toString()
      ctx.font = Style.font.caption + "px \"" + root.fontFamily + "\""
      ctx.textAlign = "left"
      ctx.textBaseline = "top"

      var ticks = root.yTicks()
      var plotBottom = root.plotHeight
      for (var i = 0; i < ticks.length; i++) {
        var y = root.yForValue(ticks[i])
        ctx.beginPath()
        ctx.moveTo(0, y)
        ctx.lineTo(w, y)
        ctx.stroke()
        if (!root.compact && ticks[i] !== 0) ctx.fillText(String(Math.trunc(ticks[i])), 2, Math.max(0, y + 2))
      }

      var xTicks = Model.axisTicks(root.windowStart, root.windowEnd, Math.max(4, Math.min(6, Math.round(w / 78))))
      ctx.textBaseline = "top"
      var prevTick = NaN
      for (var xt = 0; xt < xTicks.length; xt++) {
        var tx = root.xForTime(xTicks[xt])
        ctx.beginPath()
        ctx.strokeStyle = Util.alpha(root.gridColor, 0.18).toString()
        ctx.moveTo(tx, 0)
        ctx.lineTo(tx, plotBottom)
        ctx.stroke()

        if (root.compact) continue
        var label = Model.formatAxisTick(xTicks[xt], root.windowStart, root.windowEnd, prevTick)
        prevTick = xTicks[xt]
        ctx.fillStyle = Util.alpha(root.textColor, 0.55).toString()
        if (xt === 0) ctx.textAlign = "left"
        else if (xt === xTicks.length - 1) ctx.textAlign = "right"
        else ctx.textAlign = "center"
        ctx.fillText(label, Math.max(0, Math.min(w, tx)), plotBottom + 2)
      }

      var lists = root.useSeries ? root.plotSeries : [root.plotPoints]
      var hasLine = false
      for (var check = 0; check < lists.length; check++) {
        if (lists[check] && lists[check].length) { hasLine = true; break }
      }
      if (!hasLine) return

      for (var si = 0; si < lists.length; si++) {
        var line = lists[si] || []
        // Contiguous runs of finite points: a null cell (a data hole)
        // breaks the run, so neither the line nor the area fill bridges
        // across a gap in the data.
        var runs = []
        var run = []
        for (var p = 0; p < line.length; p++) {
          if (line[p].v === null || line[p].v === undefined || line[p].v === "" || !isFinite(Number(line[p].v))) {
            if (run.length) { runs.push(run); run = [] }
            continue
          }
          run.push({ x: root.xForTime(line[p].t), y: root.yForValue(line[p].v) })
        }
        if (run.length) runs.push(run)
        if (!runs.length) continue

        ctx.strokeStyle = root.strokeColor(si).toString()
        ctx.lineWidth = 1.75
        ctx.lineJoin = "round"
        ctx.lineCap = "round"
        ctx.beginPath()
        for (var r = 0; r < runs.length; r++) {
          ctx.moveTo(runs[r][0].x, runs[r][0].y)
          for (var q = 1; q < runs[r].length; q++) ctx.lineTo(runs[r][q].x, runs[r][q].y)
        }
        ctx.stroke()

        if (si === 0) {
          ctx.beginPath()
          for (var r = 0; r < runs.length; r++) {
            var seg = runs[r]
            ctx.moveTo(seg[0].x, seg[0].y)
            for (var q = 1; q < seg.length; q++) ctx.lineTo(seg[q].x, seg[q].y)
            ctx.lineTo(seg[seg.length - 1].x, plotBottom)
            ctx.lineTo(seg[0].x, plotBottom)
            ctx.closePath()
          }
          ctx.fillStyle = Util.alpha(root.lineColor, 0.16).toString()
          ctx.fill()
        }
      }

      if (root.hoverX >= 0 && isFinite(root.hoverT)) {
        ctx.beginPath()
        ctx.strokeStyle = Util.alpha(root.crosshairColor, 0.45).toString()
        ctx.lineWidth = 1
        ctx.moveTo(root.hoverX, 0)
        ctx.lineTo(root.hoverX, plotBottom)
        ctx.stroke()

        var dots = root.useSeries && root.hoverValues && root.hoverValues.length
          ? root.hoverValues
          : [root.hoverV]
        for (var d = 0; d < dots.length; d++) {
          if (!root.finiteValue(dots[d])) continue
          var hx = root.hoverX
          var hy = root.yForValue(dots[d])
          ctx.beginPath()
          ctx.fillStyle = root.strokeColor(d).toString()
          ctx.arc(hx, hy, 3.2, 0, Math.PI * 2)
          ctx.fill()
        }
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
    property real lastX: 0
    property bool dragging: false

    onPressed: function(event) {
      dragging = true
      lastX = event.x
      root.updateHover(event.x)
    }
    onReleased: {
      dragging = false
      if (syncHover && !containsMouse)
        root.hoverMoved(NaN)
    }
    onCanceled: {
      dragging = false
      if (syncHover && !containsMouse)
        root.hoverMoved(NaN)
    }
    onExited: {
      if (dragging) return
      if (syncHover)
        root.hoverMoved(NaN)
      else {
        root.clearHover()
        canvas.requestPaint()
      }
    }
    onPositionChanged: function(event) {
      if (dragging) {
        var dt = ((lastX - event.x) / Math.max(1, width)) * root.windowSpan
        lastX = event.x
        if (dt !== 0) root.panRequested(dt)
      }
      root.updateHover(event.x)
    }
    onWheel: function(wheel) {
      var stepped = Util.wheelSteps(root.wheelAcc, wheel.angleDelta.y)
      root.wheelAcc = stepped.remainder
      if (stepped.steps !== 0) {
        var factor = stepped.steps > 0 ? Math.pow(0.8, stepped.steps) : Math.pow(1.25, -stepped.steps)
        root.zoomRequested(factor, root.timeForX(wheel.x))
      }
      wheel.accepted = true
    }
  }

  Rectangle {
    // Show a real value, or an "—" tooltip when hovering a gap (no data
    // there), so a data hole is visible instead of a fabricated value.
    visible: root.hoverX >= 0 && (root.finiteValue(root.hoverV) || root.hoverGap)
    // Default to the left of the crosshair; when the tooltip would run off
    // the left edge (cursor near the start of the window), flip to the right
    // of the crosshair so it never covers the cursor.
    x: {
      var left = root.hoverX - implicitWidth - Style.space(8)
      if (left < 0)
        return Math.min(root.hoverX + Style.space(8), Math.max(0, parent.width - implicitWidth))
      return Math.max(0, left)
    }
    // Sit above the chart body, overlapping the section header, so the
    // tooltip never covers the plotted line or the cursor.
    y: -implicitHeight - Style.space(2) + 4
    implicitWidth: hoverLabel.implicitWidth + Style.space(10)
    implicitHeight: hoverLabel.implicitHeight + Style.space(6)
    radius: Math.min(Style.cornerRadius, height / 2)
    color: Color.popups.background
    border.width: 1
    border.color: Util.alpha(root.textColor, 0.2)

    Text {
      id: hoverLabel
      anchors.centerIn: parent
      text: root.hoverText()
      color: root.textColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }
}
