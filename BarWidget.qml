import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  // moduleName is injected by the bar. Binding it here makes the
  // property read-only and injectProps() throws before settings land.

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  readonly property color statusColor: {
    if (!netdata.connected) return Color.muted
    var key = netdata.status
    if (key === "low") return themeGreen
    if (key === "mid") return themeYellow
    if (key === "high") return Color.urgent
    return Color.muted
  }
  readonly property string hostLabel: netdata.hostLabel
  readonly property real openPanelIndicatorWidth: root.vertical ? 0 : contentRow.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))
  readonly property string tooltip: {
    if (!netdata.polling) return hostLabel + " · paused"
    if (!netdata.connected) return hostLabel + " · offline"
    return hostLabel + " GPU " + Model.formatPercent(netdata.currentValue) + "%"
  }

  property color themeGreen: "#3ecf6a"
  property color themeYellow: "#e0b44b"

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }
  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }
  function refresh() {
    netdata.refreshLatest()
    if (panelLoader.item && panelLoader.item.refreshHistory) panelLoader.item.refreshHistory()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = netdata
    if ("statusColor" in target) target.statusColor = root.statusColor
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    netdata.settings = root.settings
    injectPanel()
  }
  onStatusColorChanged: if (panelLoader.item && "statusColor" in panelLoader.item) panelLoader.item.statusColor = statusColor

  Service {
    id: netdata
    settings: root.settings
  }

  // Paused (not polling): grey square outline.
  // Playing + unreachable: grey solid circle (statusColor fallback).
  // Playing + connected: filled circle in green / yellow / red.
  component StatusMark: Rectangle {
    width: Style.space(8)
    height: Style.space(8)
    radius: netdata.polling ? width / 2 : 0
    color: netdata.polling ? root.statusColor : "transparent"
    border.width: netdata.polling ? 0 : 1
    border.color: Color.muted

    Behavior on color {
      ColorAnimation { duration: 160 }
    }
  }

  IpcHandler {
    target: "io.github.bonesgit.omarchy-netdata"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.tooltip
    fixedWidth: root.vertical ? -1 : Math.max(Style.bar.iconSlot, contentRow.implicitWidth + Style.space(16))
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }

    Row {
      id: contentRow
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(6)

      StatusMark {
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: root.hostLabel
        textFormat: Text.PlainText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    StatusMark {
      visible: root.vertical
      anchors.centerIn: parent
    }
  }
}
