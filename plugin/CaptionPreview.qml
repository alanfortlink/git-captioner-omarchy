import QtQuick

// The GIF with the caption drawn on top, laid out exactly the way
// bin/gif-captioner-render lays it out — same line height (size * 1.2), same
// 20px margin, same centering, same outline width — only scaled down from the
// output's pixel space to however big the preview is on screen. What you see
// here is what ffmpeg burns in.
Item {
  id: root

  property string source: ""
  property string caption: ""
  property string anchorMode: "bottom"   // top | middle | bottom
  property color captionColor: "white"
  property int captionSize: 32           // in OUTPUT pixels, like --size
  property int outWidth: 360             // the render's output size…
  property int outHeight: 360            // …so the caption can be scaled to match
  property bool playing: true

  readonly property int status: image.status
  readonly property real scaleFactor: outWidth > 0 && image.paintedWidth > 0
    ? image.paintedWidth / outWidth : 1

  // Trailing blank lines don't draw and don't take space (the script trims them
  // the same way); interior blanks keep their slot.
  readonly property var lines: {
    var all = String(caption).split("\n")
    while (all.length > 0 && all[all.length - 1].trim() === "") all.pop()
    return all
  }
  readonly property real lineHeight: captionSize * 1.2 * scaleFactor
  readonly property real margin: 20 * scaleFactor
  readonly property real outlineWidth: Math.max(2, Math.min(9, captionSize * 0.12)) * scaleFactor

  function lineTop(index) {
    var box = image.paintedHeight
    if (anchorMode === "top") return margin + index * lineHeight
    if (anchorMode === "middle") return (box - lines.length * lineHeight) / 2 + index * lineHeight
    return box - (lines.length - index) * lineHeight - margin
  }

  LoopingGif {
    id: image
    anchors.fill: parent
    source: root.source
    wanted: root.playing
    // A local file is seekable, so it loops without holding every decoded
    // frame in memory — and a full-size GIF is exactly where that would hurt.
    cache: String(root.source).indexOf("file://") !== 0
    fillMode: Image.PreserveAspectFit
  }

  // Overlay sized to the *painted* image, not the item: PreserveAspectFit
  // letterboxes, and the caption belongs inside the picture.
  Item {
    id: overlay
    anchors.centerIn: parent
    width: image.paintedWidth
    height: image.paintedHeight
    clip: true

    Repeater {
      model: root.lines

      Item {
        id: lineItem
        required property int index
        required property string modelData
        readonly property real pixelSize: Math.max(1, root.captionSize * root.scaleFactor)

        anchors.left: parent.left
        anchors.right: parent.right
        y: root.lineTop(lineItem.index)
        height: root.lineHeight
        visible: lineItem.modelData.trim() !== ""

        // ffmpeg's drawtext borderw is a real outline; Qt's Text.Outline is a
        // hairline, so the outline is eight offset copies of the line behind
        // the fill. Two or three lines of text at most — cheap enough.
        Repeater {
          model: [[-1, -1], [0, -1], [1, -1], [-1, 0], [1, 0], [-1, 1], [0, 1], [1, 1]]

          Text {
            required property var modelData
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.horizontalCenterOffset: modelData[0] * root.outlineWidth * 0.5
            y: modelData[1] * root.outlineWidth * 0.5
            text: lineItem.modelData
            color: "#e6000000"
            font.pixelSize: lineItem.pixelSize
            font.bold: true
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: lineItem.modelData
          color: root.captionColor
          font.pixelSize: lineItem.pixelSize
          font.bold: true
        }
      }
    }
  }
}
