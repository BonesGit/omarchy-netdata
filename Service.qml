import QtQuick
import "Model.js" as Model

// Plugin `service` singleton. The shell mounts this once. Dual-monitor
// pills call pollerFor(settings) and share one Poller per host+context.
Item {
  id: root
  width: 0
  height: 0
  visible: false

  property var _pollers: ({})
  property var _pollerComp: null

  function pollerComponent() {
    if (_pollerComp) return _pollerComp
    _pollerComp = Qt.createComponent(Qt.resolvedUrl("Poller.qml"), Component.PreferSynchronous)
    return _pollerComp
  }

  function pollerFor(settings) {
    var key = Model.pollerKey(settings)
    var existing = root._pollers[key]
    if (existing) {
      existing.settings = settings || ({})
      return existing
    }
    var comp = pollerComponent()
    if (!comp) return null
    if (comp.status === Component.Loading) return null
    if (comp.status !== Component.Ready) {
      console.warn("omarchy-netdata: poller load failed:", comp.errorString())
      return null
    }
    var poller = comp.createObject(root, { settings: settings || ({}) })
    if (!poller) {
      console.warn("omarchy-netdata: poller createObject returned null for", key)
      return null
    }
    var next = ({})
    for (var k in root._pollers) next[k] = root._pollers[k]
    next[key] = poller
    root._pollers = next
    return poller
  }
}
