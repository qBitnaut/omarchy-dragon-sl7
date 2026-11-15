pragma Singleton
import QtQuick

QtObject {
  id: root

  property int cornerRadius: 0

  function space(px) {
    return px
  }

  readonly property QtObject font: QtObject {
    readonly property string family: "monospace"
    readonly property int heading: 16
  }
}
