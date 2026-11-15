import QtQuick

Item {
  property string text: ""
  property string iconText: ""
  property bool bordered: false
  property color foreground: "#ffffff"
  property color background: "transparent"
  property real fontSize: 12
  property real iconSize: 12
  signal clicked()
}
