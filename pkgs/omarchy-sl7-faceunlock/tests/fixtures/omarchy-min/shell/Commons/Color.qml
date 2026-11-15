// Minimal fixture: only what the lock overlay reads.
pragma Singleton
import QtQuick

QtObject {
  id: root

  property color background: "#000000"

  readonly property QtObject lock: QtObject {
    property color background: "#000000"
    property color text: "#ffffff"
    property color placeholder: "#888888"
    property color textError: "#ff0000"
    property color borderActive: "#00ff00"
    property color borderError: "#ff0000"
    property color selection: "#0000ff"
  }
}
