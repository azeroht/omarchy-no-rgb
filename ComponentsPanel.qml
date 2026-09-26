import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Lighting panel, in the style of the native panels: global on / off, then
// every component (RAM, GPU, cooler, motherboard...) to include or exclude.
// Each choice goes up through requested(action, name, value), turned into an
// rgb.sh call by the bar widget.
Column {
  id: panel
  property var lighting: Model.DEFAULTS
  property var components: []
  property bool isLoading: false
  property bool busy: false
  signal requested(string action, var name, var value)
  readonly property int panelWidth: Style.space(320)
  readonly property color foreground: Color.popups.text
  readonly property real captionOpacity: 0.6
  // Lights off: the components stay adjustable, but greyed out.
  readonly property real inactiveOpacity: 0.5
  readonly property real rowGap: Style.space(8)
  readonly property var rows: Model.withMissing(components, lighting)

  spacing: Style.spacing.panelGap

  PanelHero {
    title: "RGB"
    meta: panel.busy ? "Applying..." : (panel.lighting.enabled ? "On" : "Off")
    foreground: panel.foreground
    iconComponent: Component {
      Text {
        // Nerd Font: led-strip.
        text: "\u{f07d6}"
        color: panel.lighting.enabled ? Color.urgent : panel.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.display
      }
    }
    trailingControl: Component {
      ToggleSwitch {
        checked: panel.lighting.enabled
        foreground: panel.foreground
        onToggled: panel.requested(panel.lighting.enabled ? "off" : "on", undefined, undefined)
      }
    }
  }

  PanelSeparator { foreground: panel.foreground }

  PanelSectionHeader { text: "COMPONENTS"; foreground: panel.foreground; fontSize: Style.font.bodySmall }

  Text {
    width: parent.width
    visible: panel.rows.length === 0
    wrapMode: Text.WordWrap
    text: panel.isLoading ? "Looking for components..." : "No component found. Is the OpenRGB server running?"
    color: panel.foreground
    opacity: panel.captionOpacity
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  Repeater {
    model: panel.rows

    Item {
      id: row
      required property var modelData
      readonly property bool isIncluded: Model.isComponentEnabled(panel.lighting, modelData.name)

      width: panel.width
      implicitHeight: Math.max(labels.implicitHeight, toggle.implicitHeight)
      opacity: panel.lighting.enabled ? 1 : panel.inactiveOpacity

      Column {
        id: labels
        anchors.left: parent.left
        anchors.right: toggle.left
        anchors.rightMargin: panel.rowGap
        anchors.verticalCenter: parent.verticalCenter

        Text {
          width: parent.width
          text: row.modelData.label
          textFormat: Text.PlainText
          color: panel.foreground
          elide: Text.ElideRight
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          text: row.modelData.isMissing ? "Not detected by OpenRGB" : row.modelData.name
          textFormat: Text.PlainText
          color: panel.foreground
          opacity: panel.captionOpacity
          elide: Text.ElideRight
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      ToggleSwitch {
        id: toggle
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        checked: row.isIncluded
        foreground: panel.foreground
        onToggled: panel.requested("component", row.modelData.name, row.isIncluded ? "off" : "on")
      }
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "An excluded component stays dark while the others are lit. Color and effect: rgb.sh help."
    color: panel.foreground
    opacity: panel.captionOpacity
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}
