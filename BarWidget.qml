import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// No RGB: RGB lighting on / off through OpenRGB, from the bar.
// Left click: lights on / off, the icon turns red while they are on.
// Right click: the components (RAM, GPU, cooler, motherboard...), each one
// included or excluded. Color and effect stay the saved ones (rgb.sh).
// Every monitor has its own bar, hence its own instance of this widget: they
// all follow the state file, and only the instance on the first screen
// reapplies the saved state when the shell starts.
BarWidget {
  id: root
  moduleName: "azeroht.no-rgb"

  property var lighting: Model.DEFAULTS
  property var components: []
  property bool popupOpen: false
  property bool isRestored: false
  // Each call takes about two seconds: commands run one at a time.
  property var queue: []
  readonly property bool busy: runner.running || queue.length > 0
  readonly property real busyOpacity: 0.5
  readonly property string scriptPath: String(Qt.resolvedUrl("rgb.sh")).replace("file://", "")
  readonly property bool isPrimary: {
    const window = root.QsWindow.window
    return !!window && Quickshell.screens.length > 0 && window.screen === Quickshell.screens[0]
  }

  // Contract the bar expects to open and close the popup.
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }

  // An IPC target reaches a single instance: it relays open to every bar, and
  // only the one on the focused monitor opens its panel.
  function openIfFocused() {
    const window = root.QsWindow.window
    const focused = Hyprland.focusedMonitor
    if (window && window.screen && focused && window.screen.name === focused.name) open()
  }

  function run(action, name, value) {
    queue = queue.concat([Model.command(scriptPath, action, name, value)])
    if (!runner.running) runNext()
  }

  function runNext() {
    if (queue.length === 0) return
    runner.command = queue[0]
    queue = queue.slice(1)
    runner.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The saved lighting comes back once per shell start, from the first screen.
  function restoreOnce() {
    if (!isPrimary || isRestored) return
    isRestored = true
    run("restore")
  }

  Component.onCompleted: restoreOnce()
  onIsPrimaryChanged: restoreOnce()

  onPopupOpenChanged: if (popupOpen && !componentsProcess.running) componentsProcess.running = true

  // omarchy-shell azeroht.no-rgb toggle | on | off | open | close | status
  IpcHandler {
    target: "azeroht.no-rgb"
    function toggle(): void { root.run("toggle") }
    function on(): void { root.run("on") }
    function off(): void { root.run("off") }
    function open(): void { root.broadcast("openIfFocused") }
    function close(): void { root.broadcast("close") }
    function status(): string { return Model.describe(root.lighting) }
  }

  FileView {
    path: Color.stateHome + "/azeroht-no-rgb.json"
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.lighting = Model.normalize(Model.parse(text()))
  }

  // On failure, rgb.sh tells the user itself through a notification.
  Process {
    id: runner
    onExited: root.runNext()
  }

  Process {
    id: componentsProcess
    command: [root.scriptPath, "components"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.components = Model.parseComponents(text)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    opacity: root.busy ? root.busyOpacity : 1
    // Nerd Font: led-strip.
    text: "\u{f07d6}"
    active: root.lighting.enabled
    tooltipText: "RGB: " + Model.describe(root.lighting)
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.popupOpen = !root.popupOpen
      else root.run("toggle")
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(panel.panelWidth)
    contentHeight: popup.fittedContentHeight(panel.implicitHeight)

    ComponentsPanel {
      id: panel
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      lighting: root.lighting
      components: root.components
      isLoading: componentsProcess.running
      busy: root.busy
      onRequested: function(action, name, value) { root.run(action, name, value) }
    }
  }
}
