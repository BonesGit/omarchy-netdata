import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A companion metric section under the utilization chart: a title +
// current-value header and a compact, auto-scaled line chart locked to
// the same time window as the utilization chart. Used for temperature,
// memory, and power. The header value and hover tooltip format by
// `temperature` (degrees) or `units` (B / Watts / ...). Pan/zoom/hover are
// re-emitted to the Panel so every chart stays on the shared window and the
// crosshair is kept in sync.
Column {
  id: root

  property string title: ""
  property var points: []
  property var series: []
  property real windowStart: 0
  property real windowEnd: 0
  property bool live: true
  property var units: ""
  property var splitValues: []
  property real chartHeight: 0
  property bool temperature: false
  // Set by the Panel: show the section once this metric's context is
  // configured (mirrors the utilization/temperature visibility rule).
  property bool enabled: false
  // Resolved from the bar by the Panel (a child component can't see the
  // host's `bar` property on its own).
  property color fg: Color.foreground
  property color fgDim: Qt.darker(Color.foreground, 1.4)
  property string fontFam: Style.font.family

  readonly property bool hoverActive: chart ? chart.hoverActive : false
  readonly property string valueText: {
    var vals = splitValues
    if (vals && vals.length > 1) {
      if (temperature) return Model.formatValueList(vals, Model.formatTemp)
      return Model.formatValueList(vals, function(v) { return Model.formatMetric(v, units) })
    }
    var last = Model.latestValue(points)
    if (last === null || last === undefined) return ""
    return temperature ? Model.formatTemp(last) : Model.formatMetric(last, units)
  }

  signal zoomRequested(real factor, real anchorSec)
  signal panRequested(real deltaSec)
  signal hoverMoved(real t)

  Column {
    width: parent.width
    visible: root.enabled
    height: visible ? implicitHeight : 0
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(titleLabel.implicitHeight, valueLabel.implicitHeight)

      Text {
        id: titleLabel
        anchors.left: parent.left
        anchors.right: valueLabel.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: root.title
        textFormat: Text.PlainText
        color: root.fg
        font.family: root.fontFam
        font.pixelSize: Style.font.subtitle
        elide: Text.ElideRight
      }

      Text {
        id: valueLabel
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.valueText !== "" ? root.valueText : "—"
        color: root.fgDim
        font.family: root.fontFam
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }
    }

    GpuChart {
      id: chart
      width: parent.width
      height: root.chartHeight
      points: root.points
      series: root.series
      windowStart: root.windowStart
      windowEnd: root.windowEnd
      live: root.live
      autoScale: true
      compact: true
      temperature: root.temperature
      metricUnits: root.temperature ? "" : root.units
      syncHover: true
      lineColor: Color.accent
      secondaryColor: Color.urgent
      gridColor: Color.muted
      textColor: root.fg
      crosshairColor: root.fg
      fontFamily: root.fontFam
      onZoomRequested: function(factor, anchor) { root.zoomRequested(factor, anchor) }
      onPanRequested: function(delta) { root.panRequested(delta) }
      onHoverMoved: function(t) { root.hoverMoved(t) }
    }
  }

  function applyHoverTime(t) {
    if (chart) chart.applyHoverTime(t)
  }
}
