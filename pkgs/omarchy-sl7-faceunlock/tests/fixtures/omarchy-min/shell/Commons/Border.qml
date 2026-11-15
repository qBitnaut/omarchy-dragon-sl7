pragma Singleton
import QtQuick

QtObject {
  function surfaceSpec(section, token, fallbackColor, fallbackWidth, alphaKey) {
    return { color: fallbackColor, widths: fallbackWidth }
  }
}
