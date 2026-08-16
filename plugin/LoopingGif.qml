import QtQuick

// An AnimatedImage that ignores the GIF's own loop count.
//
// Plenty of Giphy files (and most of their downsampled preview variants) carry
// a finite NETSCAPE loop count, so Qt plays them the stated number of times and
// then stops on the last frame — a thumbnail grid that freezes a few seconds
// after a search, and a caption preview that dies while you are still typing.
// Rewind and start again whenever playback ends while it is still wanted.
AnimatedImage {
  id: root

  // Play while this is true; set it false to freeze (panel closed, other stage).
  property bool wanted: true

  cache: false
  asynchronous: true
  playing: false          // driven by sync(), never bound: Qt writes to it too

  function sync() {
    if (!wanted) {
      playing = false
      return
    }
    if (status !== AnimatedImage.Ready || playing) return
    currentFrame = 0
    playing = true
  }

  onWantedChanged: sync()
  onStatusChanged: sync()
  onSourceChanged: rewind.restart()
  // Qt stops playback at the end of the last loop; that is our cue to go again.
  onPlayingChanged: if (wanted && !playing) rewind.restart()

  Component.onCompleted: sync()

  // One turn of the event loop, so the restart never re-enters the change
  // handler that scheduled it.
  Timer {
    id: rewind
    interval: 20
    onTriggered: root.sync()
  }
}
