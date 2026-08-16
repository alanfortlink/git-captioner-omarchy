import QtQuick

// An AnimatedImage that actually loops.
//
// Qt plays a GIF straight off the network reply, and a network reply cannot be
// rewound: with `cache: false` the movie reaches its last frame and stops dead
// there — `playing` goes false and no amount of restarting brings it back —
// even though the file says "loop forever". Caching the frames makes the movie
// seekable, so it loops on its own. (A GIF from a *local file* loops without
// the cache, which is why the caption preview downloads first and points here
// at a file:// URL.)
//
// The restart below is the belt to that pair of braces: a file with a finite
// loop count still ends, and a preview that freezes mid-typing looks broken.
AnimatedImage {
  id: root

  // Play while this is true; set it false to freeze (panel closed, other stage).
  property bool wanted: true

  cache: true
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
