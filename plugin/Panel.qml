import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon + popup panel: search Giphy, pick a GIF, caption it, and get the
// captioned GIF and MP4 onto the clipboard. Three stages in one panel — a
// search grid, a caption editor and a settings page — mirroring the keyboard
// model of the gif-captioner TUI (type, Enter to search, hjkl in the grid,
// Enter to pick, Ctrl+Enter to render, Esc to go back).
//
// The heavy lifting is not done here: bin/gif-captioner-render downloads,
// renders and copies, and this panel only reads its progress lines. Nothing
// blocks the shell process.
Panel {
  id: root
  moduleName: "alanfortlink.gif-captioner"
  ipcTarget: "alanfortlink.gif-captioner"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // <repo>/plugin/Panel.qml -> <repo>/bin/gif-captioner-render
  readonly property string repoDir: decodeURIComponent(String(Qt.resolvedUrl(".."))
    .replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string renderScript: repoDir + "/bin/gif-captioner-render"
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (homeDir + "/.config")
  readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || (homeDir + "/.cache")
  readonly property string keyFile: configHome + "/gif-captioner/config"
  readonly property string mediaDir: cacheHome + "/gif-captioner/media"

  // ---- state ----
  // None of this survives closing the panel: every open starts on an empty
  // search (see reset()). Only the settings — key, shortcut, caption defaults —
  // persist, and those live in files, not here.
  property string stage: "search"          // "search" | "edit" | "settings"
  property string giphyKey: ""
  readonly property bool hasKey: giphyKey !== ""
  property var results: []
  property int cursor: 0
  property string searchFocus: "field"     // "field" | "grid" — where the cursor was
  property bool searching: false
  property string statusText: ""
  property int searchSeq: 0
  property string activeQuery: ""          // the query the current results came from
  property int nextOffset: 0               // where the next page starts
  property int totalResults: 0             // what Giphy claims exists for the query
  property bool pageWasFull: false         // the last page came back full → there is more

  property var selected: null              // the picked result, or null
  property string caption: ""
  property string anchorMode: String(setting("anchor", "Bottom")).toLowerCase()
  property string captionColor: Model.normalizeHex(setting("color", "#ffffff")) || "#ffffff"
  property int captionSize: setting("fontSize", 20)
  // What a render puts on the clipboard. A Wayland claim carries one
  // representation and the last claim wins, so "both" means claiming twice: the
  // MP4 first, the GIF second, leaving two entries in your clipboard history to
  // choose between (WhatsApp Web, for one, flattens a pasted GIF image but
  // takes the MP4 file happily).
  readonly property var copyModes: ({ "GIF and MP4": "both", "GIF file": "gif-file",
                                      "MP4 file": "mp4-file", "GIF image": "gif-image" })
  readonly property string copyAs: copyModes[String(setting("copy", "GIF and MP4"))] || "both"
  // Tools the render script needs. Checked at startup and on every open, so a
  // half-installed system says so instead of failing at render time.
  property var missingTools: []
  readonly property var toolPackages: ({ "ffmpeg": "ffmpeg", "ffprobe": "ffmpeg", "curl": "curl",
                                         "wl-copy": "wl-clipboard", "fc-match": "fontconfig" })
  readonly property var missingPackages: {
    var seen = [], out = []
    for (var i = 0; i < missingTools.length; i++) {
      var pkg = toolPackages[missingTools[i]] || missingTools[i]
      if (seen.indexOf(pkg) === -1) { seen.push(pkg); out.push(pkg) }
    }
    return out
  }
  readonly property string installCommand: "sudo pacman -S --needed " + missingPackages.join(" ")

  property int editField: 0                // 0 caption · 1 position · 2 color · 3 size
  property int settingsField: 0            // 0 API key · 1 shortcut

  // Colour picker. Typing a hex still works; this is for the other 95% of the
  // time, when you just want white, or yellow, or that red.
  readonly property var palette: ["#ffffff", "#000000", "#ffe600", "#ff9500",
                                  "#ff3b30", "#ff2d95", "#af52de", "#5856d6",
                                  "#0a84ff", "#32ade6", "#34c759", "#8e8e93"]
  readonly property int paletteColumns: 6
  property bool paletteOpen: false
  property int paletteIndex: 0

  function togglePalette() {
    if (paletteOpen) { paletteOpen = false; restoreFocus(); return }
    var at = palette.indexOf(captionColor)
    paletteIndex = at < 0 ? 0 : at
    paletteOpen = true
    restoreFocus()
  }

  function movePalette(delta) {
    if (!paletteOpen) return
    var next = paletteIndex + delta
    if (next < 0 || next >= palette.length) return
    paletteIndex = next
  }

  function pickPalette(index) {
    if (index < 0 || index >= palette.length) return
    captionColor = palette[index]
    colorField.text = captionColor
    paletteOpen = false
    restoreFocus()
  }
  property bool rendering: false
  property string lastGif: ""
  property string lastMp4: ""

  readonly property int columns: 3
  readonly property int visibleRows: 3
  readonly property var outSize: selected
    ? Model.outputSize(selected.width, selected.height)
    : ({ width: Model.MAX_WIDTH, height: Model.MAX_WIDTH })

  // The item that should own the keyboard for the current state. The panel
  // focuses it on every open, and restoreFocus() re-asserts it after a stage or
  // field change.
  readonly property Item focusItem: {
    if (stage === "settings") return settingsField === 1 ? shortcutRow : keyField
    if (stage === "edit")
      return editField === 1 ? anchorGroup
           : editField === 2 ? colorField
           : editField === 3 ? sizeField : captionField
    return searchFocus === "grid" && results.length > 0 ? keyCatcher : searchField
  }

  // The grid's hjkl cursor only makes sense while the grid itself has the
  // keyboard: any text field, and the whole caption stage, own their keys.
  readonly property bool fieldFocused: searchField.activeFocus || keyField.activeFocus
    || captionField.activeFocus || colorField.activeFocus || sizeField.activeFocus

  function restoreFocus() {
    Qt.callLater(function() {
      if (!root.opened || !root.focusItem) return
      root.focusItem.forceActiveFocus()
    })
  }

  // Back to a blank slate: no query, no results, no caption. Called when the
  // panel closes so the next open is always a fresh search.
  function reset() {
    stage = hasKey ? "search" : "settings"
    searchField.text = ""
    results = []
    cursor = 0
    searchFocus = "field"
    searching = false
    searchSeq++              // a search still in flight lands on nothing
    activeQuery = ""
    nextOffset = 0
    totalResults = 0
    pageWasFull = false
    selected = null
    previewFile = ""
    caption = ""
    captionField.text = ""
    editField = 0
    lastGif = ""
    lastMp4 = ""
    statusText = ""
    capturingShortcut = false
    // Caption defaults come back from the widget's settings, not from the last
    // GIF you captioned.
    anchorMode = String(setting("anchor", "Bottom")).toLowerCase()
    captionColor = Model.normalizeHex(setting("color", "#ffffff")) || "#ffffff"
    captionSize = setting("fontSize", 20)
    keyField.text = giphyKey
  }

  function openSettings() {
    stage = "settings"
    statusText = ""
    settingsField = 0
    keyField.text = giphyKey
    restoreFocus()
  }

  function focusSettingsField(index) {
    settingsField = ((index % 2) + 2) % 2
    restoreFocus()
  }

  // Tab walks the settings page the same way it walks the caption stage, and
  // Esc backs out — the two controls handle the rest themselves.
  function settingsKey(event) {
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      focusSettingsField(settingsField + ((event.modifiers & Qt.ShiftModifier)
        || event.key === Qt.Key_Backtab ? -1 : 1))
    } else if (event.key === Qt.Key_Escape) {
      if (capturingShortcut) { capturingShortcut = false; restoreFocus() }
      else if (hasKey) backToSearch()
      else close()
    } else {
      return
    }
    event.accepted = true
  }

  onOpenedChanged: {
    if (!opened) { reset(); return }
    if (!toolsProc.running) toolsProc.running = true
    restoreFocus()
  }

  // ---- keyboard shortcut ----
  // The widget owns its own shortcut: set it on the settings page (the gear in
  // the search bar) or in the widget's settings, and the panel registers it
  // with Hyprland itself — nobody has to hand-edit bindings.lua. It is a
  // runtime bind, so it leaves no trace in your config and disappears with the
  // plugin; a Hyprland config reload drops it, so we re-apply on
  // `configreloaded`.
  //
  // shortcutLocal is what the settings page just captured: it applies at once,
  // while `omarchy bar set` persists the same value into shell.json for the
  // next session.
  property var shortcutLocal: null
  readonly property string shortcut: shortcutLocal !== null
    ? String(shortcutLocal).trim() : String(setting("shortcut", "")).trim()
  property string boundSpec: ""            // what Hyprland currently has from us
  property bool capturingShortcut: false

  function setShortcut(text) {
    shortcutLocal = String(text)
    saveShortcutProc.command = ["omarchy", "bar", "set", moduleName, "shortcut", String(text)]
    saveShortcutProc.running = true
  }

  // Turn a key event into "SUPER + ALT + G". Returns "" for a modifier-only
  // press (the user is still holding the combination down) or a key we cannot
  // name for Hyprland.
  function shortcutFromEvent(event) {
    var named = ({})
    named[Qt.Key_Space] = "SPACE"
    named[Qt.Key_Return] = "RETURN"
    named[Qt.Key_Enter] = "RETURN"
    named[Qt.Key_Tab] = "TAB"
    named[Qt.Key_Backspace] = "BACKSPACE"
    named[Qt.Key_Insert] = "INSERT"
    named[Qt.Key_Delete] = "DELETE"
    named[Qt.Key_Home] = "HOME"
    named[Qt.Key_End] = "END"
    named[Qt.Key_PageUp] = "PRIOR"
    named[Qt.Key_PageDown] = "NEXT"
    named[Qt.Key_Left] = "LEFT"
    named[Qt.Key_Right] = "RIGHT"
    named[Qt.Key_Up] = "UP"
    named[Qt.Key_Down] = "DOWN"

    var key = ""
    if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F12)
      key = "F" + (event.key - Qt.Key_F1 + 1)
    else if (named[event.key] !== undefined)
      key = named[event.key]
    else if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z)
      key = String.fromCharCode(event.key)
    else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9)
      key = String.fromCharCode(event.key)
    if (key === "") return ""

    var mods = []
    if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (event.modifiers & Qt.AltModifier) mods.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")
    return mods.concat([key]).join(" + ")
  }

  Process { id: saveShortcutProc }

  // "SUPER ALT G" / "super+alt+g" / "SUPER, ALT, G" -> "SUPER + ALT + G", the
  // shape Hyprland's Lua hl.bind() takes. Anything with characters outside
  // [A-Za-z0-9_] is rejected rather than passed into the Lua snippet below.
  readonly property string wantedSpec: {
    var raw = String(shortcut).replace(/[+,]/g, " ").trim()
    if (raw === "" || !/^[A-Za-z0-9_ ]+$/.test(raw)) return ""
    return raw.split(/\s+/).map(function(part) { return part.toUpperCase() }).join(" + ")
  }
  readonly property bool shortcutInvalid: shortcut !== "" && wantedSpec === ""
  // Set when the combination is already bound by something else (the user's own
  // config, another plugin): we refuse to take it rather than silently stealing
  // a binding we could never give back.
  property string shortcutTaken: ""
  readonly property string bindDescription: "GIF Captioner"

  // The bar builds one copy of this widget per monitor, and rebuilds all of
  // them on every layout change. Only one copy may own the keybinding,
  // otherwise a copy being torn down unbinds the shortcut the new copy just
  // registered. The copy on Quickshell's first screen is the owner; when
  // monitors change, the new first screen's copy takes over.
  readonly property string screenName: QsWindow.window && QsWindow.window.screen
    ? String(QsWindow.window.screen.name || "") : ""
  readonly property bool shortcutOwner: {
    var screens = Quickshell.screens
    if (!screens || screens.length === 0 || screenName === "") return false
    return screenName === String(screens[0].name || "")
  }
  onShortcutOwnerChanged: if (shortcutOwner) applyShortcut(true)

  // Hyprland with Omarchy's Lua config has no `hyprctl keyword bind` ("keyword
  // can't work with non-legacy parsers"), so the bind is registered by
  // evaluating the same hl.bind() call the config files use.
  // Every copy checks for a conflict (so the warning shows on whichever monitor
  // you open the panel on); only the owner actually binds.
  function applyShortcut(force) {
    if (!force && wantedSpec === boundSpec) return
    // Ask Hyprland what is on that combination first; bindNow() finishes the
    // job once the answer is in.
    conflictProc.pendingForce = !!force
    conflictProc.running = false
    conflictProc.running = true
  }

  // modmask as Hyprland reports it in `hyprctl binds -j`.
  function modMaskFor(spec) {
    var bits = { "SHIFT": 1, "CAPS": 2, "CTRL": 4, "CONTROL": 4, "ALT": 8,
                 "MOD2": 16, "MOD3": 32, "SUPER": 64, "WIN": 64, "MOD5": 128 }
    var parts = String(spec).split("+").map(function(p) { return p.trim().toUpperCase() })
    var mask = 0
    for (var i = 0; i < parts.length - 1; i++) mask |= (bits[parts[i]] || 0)
    return mask
  }
  function keyOf(spec) {
    var parts = String(spec).split("+")
    return parts.length ? parts[parts.length - 1].trim().toUpperCase() : ""
  }

  function bindNow(binds) {
    var previous = boundSpec

    // No readable bind list means we cannot tell a free combination from a
    // taken one — and binding blind would silently drop someone else's
    // binding. Try again shortly instead.
    if (!Array.isArray(binds) || binds.length === 0) {
      retryBindTimer.restart()
      return
    }

    var conflict = ""
    var stale = false          // a bind of ours left behind by a previous shell
    if (wantedSpec !== "") {
      var mask = modMaskFor(wantedSpec), key = keyOf(wantedSpec)
      for (var i = 0; i < binds.length; i++) {
        var b = binds[i]
        if (!b || Number(b.modmask) !== mask) continue
        if (String(b.key || "").toUpperCase() !== key) continue
        if (String(b.description || "") === bindDescription) { stale = true; continue }
        conflict = String(b.description || "another binding")
        break
      }
    }
    shortcutTaken = conflict
    if (!shortcutOwner) { boundSpec = ""; return }
    boundSpec = conflict === "" ? wantedSpec : ""

    var lua = ""
    if (previous !== "" && previous !== boundSpec) lua += 'hl.unbind("' + previous + '") '
    if (boundSpec !== "") {
      // Only ever unbind a bind of our own: a shell killed without running
      // onDestruction (any omarchy-restart-shell) leaves one behind, and two
      // binds on one combination would toggle the panel twice — i.e. do
      // nothing. Anything else on that combination is someone else's and is
      // treated as a conflict above.
      if (stale) lua += 'hl.unbind("' + boundSpec + '") '
      // Toggle through the shell target, not our own IPC target: the bar routes
      // `shell toggle` to the widget instance on the focused monitor, while a
      // per-widget IPC call always lands on whichever monitor's instance
      // registered the target first (so the panel would open on that monitor no
      // matter where you are).
      lua += 'hl.bind("' + boundSpec + '", hl.dsp.exec_cmd("omarchy-shell shell toggle '
           + moduleName + ' \'{}\'"), { description = "' + bindDescription + '" })'
    }
    if (lua === "") return
    bindProc.command = ["hyprctl", "eval", lua]
    bindProc.running = true
  }

  onWantedSpecChanged: applyShortcut(false)

  // hyprctl is not always answering the moment the shell starts; a couple of
  // retries is the difference between "shortcut works" and "shortcut silently
  // never registered".
  Timer {
    id: retryBindTimer
    interval: 1000
    repeat: false
    property int attempts: 0
    onTriggered: {
      if (attempts++ > 5) return
      root.applyShortcut(true)
    }
  }

  Process {
    id: conflictProc
    property bool pendingForce: false
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var binds = []
        try { binds = JSON.parse(String(text)) } catch (e) { binds = [] }
        root.bindNow(binds)
      }
    }
    stderr: StdioCollector { }
  }

  Process {
    id: bindProc
    stderr: StdioCollector { onStreamFinished: bindProc.errText = String(text).trim() }
    property string errText: ""
    onExited: function(code) {
      if (code === 0) { bindProc.errText = ""; return }
      // Hyprland refused the bind (or hyprctl is missing): say so instead of
      // leaving a shortcut that silently never fires.
      root.bindError = bindProc.errText !== "" ? bindProc.errText
                                               : "hyprctl exited " + code
      root.boundSpec = ""
      bindProc.errText = ""
    }
  }
  property string bindError: ""
  onBoundSpecChanged: if (boundSpec !== "") bindError = ""

  // A Hyprland reload drops runtime binds; put ours back.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && String(event.name) === "configreloaded") root.applyShortcut(true)
    }
  }

  Component.onCompleted: {
    toolsProc.running = true
    applyShortcut(true)
  }

  // The bar can destroy a sibling copy of this widget right after we bound —
  // its unbind would land last. Re-assert shortly after startup so the binding
  // survives a layout rebuild.
  Timer {
    interval: 1500
    running: root.shortcutOwner && root.wantedSpec !== ""
    repeat: false
    onTriggered: root.applyShortcut(true)
  }

  // Disabling or removing the widget takes its shortcut with it.
  Component.onDestruction: {
    if (boundSpec === "") return
    Quickshell.execDetached(["hyprctl", "eval", 'hl.unbind("' + boundSpec + '")'])
  }

  // ---- search ----
  // Giphy pages with limit/offset. Page 1 replaces the grid; every page after
  // it is appended, so the grid just keeps going as you walk down it.
  function search(offset) {
    var page = Math.max(0, offset || 0)
    var query = page > 0 ? activeQuery : searchField.text.trim()
    if (query === "" || !hasKey || searching) return
    if (page > Model.MAX_OFFSET) return
    activeQuery = query
    searching = true
    statusText = page > 0 ? "Loading more…" : "Searching “" + query + "”…"
    searchSeq++
    searchProc.seq = searchSeq
    searchProc.offset = page
    searchProc.running = false
    // The key goes through the environment, never argv: /proc/<pid>/cmdline is
    // world-readable, so a key on the command line is a key any local process
    // can read for the length of the request.
    searchProc.environment = ({ "GIF_CAPTIONER_GIPHY_KEY": giphyKey })
    searchProc.command = ["sh", "-c",
      'exec curl -fsS --max-time 10 --get' +
      ' --data-urlencode "api_key=$GIF_CAPTIONER_GIPHY_KEY"' +
      ' --data-urlencode "q=$1" --data-urlencode "limit=$2" --data-urlencode "offset=$3"' +
      ' --data-urlencode "rating=$4" --data-urlencode "bundle=messaging_non_clips" -- "$5"',
      "gif-captioner-search", query, String(Model.PAGE_SIZE), String(page),
      String(setting("rating", "pg-13")), Model.ENDPOINT]
    searchProc.running = true
  }

  function applyResults(page, offset) {
    var list = page.items || []
    searching = false
    totalResults = page.total || 0
    // A short page means Giphy has nothing more for this query.
    pageWasFull = list.length >= Model.PAGE_SIZE

    if (offset > 0) {
      if (list.length === 0) { statusText = ""; return }
      results = results.concat(list)
      nextOffset = offset + list.length
      statusText = ""
      return
    }

    results = list
    cursor = 0
    nextOffset = list.length
    statusText = list.length === 0 ? "No results." : ""
    if (list.length > 0) focusGrid()
  }

  // Is there another page, and are we allowed to ask for it?
  readonly property bool hasMore: results.length > 0 && pageWasFull
    && nextOffset <= Model.MAX_OFFSET
    && (totalResults === 0 || results.length < totalResults)

  // Load the next page as the cursor (or a scroll) reaches the last row, so
  // walking down the grid never stops at 25.
  function maybeLoadMore() {
    if (!hasMore || searching) return
    if (cursor >= results.length - columns) search(nextOffset)
  }

  function focusGrid() {
    if (results.length === 0) return
    searchFocus = "grid"
    keyCatcher.forceActiveFocus()
    grid.positionViewAtIndex(cursor, GridView.Contain)
  }

  function focusQuery() {
    searchFocus = "field"
    searchField.forceActiveFocus()
    searchField.selectAll()
  }

  function setCursor(index) {
    if (index < 0 || index >= results.length) return
    cursor = index
    grid.positionViewAtIndex(cursor, GridView.Contain)
    maybeLoadMore()
  }

  function moveCursor(dx, dy) {
    if (stage !== "search" || results.length === 0) return
    if (dy < 0 && cursor < columns) { focusQuery(); return }
    var next = cursor + dx + dy * columns
    if (dx !== 0 && Math.floor(next / columns) !== Math.floor(cursor / columns)) return
    if (dy > 0 && next >= results.length) next = results.length - 1
    setCursor(next)
  }

  // Single characters the grid understands beyond hjkl (PanelKeyCatcher hands
  // them over as textKey), mirroring the gif-captioner TUI.
  function gridTextKey(text) {
    if (stage !== "search") return
    if (text === "/") { focusQuery(); return }
    if (text === ",") { openSettings(); return }
    if (text === "n") { search(nextOffset); return }     // the TUI's next-page key
    if (text === "g") setCursor(0)
    else if (text === "G") setCursor(results.length - 1)
  }

  // ---- caption stage ----
  function openEditor(index) {
    if (index < 0 || index >= results.length) return
    // The caption is kept on purpose: picking a different GIF for the same line
    // is the common second try.
    selected = results[index]
    lastGif = ""
    lastMp4 = ""
    previewFile = ""
    fetchPreview()
    stage = "edit"
    statusText = ""
    focusEditField(0)
  }

  // The preview plays from a local copy, not from the URL: Qt cannot rewind a
  // network reply, so a streamed GIF stops on its last frame, and caching every
  // frame of a full-size GIF in the shell's memory is not the answer either.
  // The thumbnail stands in until the file lands.
  property string previewFile: ""
  function fetchPreview() {
    if (!selected) return
    var id = String(selected.id || "").replace(/[^A-Za-z0-9_-]/g, "")
    if (id === "") return
    var path = mediaDir + "/" + id + ".gif"
    previewProc.running = false
    previewProc.target = path
    previewProc.command = ["sh", "-c",
      'dir=$1; out=$2; url=$3; mkdir -p "$dir" || exit 1; ' +
      '[ -s "$out" ] || curl -fsSL --proto "=https" --proto-redir "=https" --max-redirs 5 ' +
      '  --max-filesize 67108864 --max-time 30 -o "$out.part" -- "$url" || exit 1; ' +
      '[ -f "$out.part" ] && mv -f "$out.part" "$out"; ' +
      // Keep the newest 40 files, so browsing a few searches does not grow
      // without bound.
      'ls -1t "$dir"/*.gif 2>/dev/null | tail -n +41 | while read -r old; do rm -f -- "$old"; done; ' +
      'exit 0',
      "gif-captioner-preview", mediaDir, path, String(selected.url)]
    previewProc.running = true
  }

  Process {
    id: previewProc
    property string target: ""
    stderr: StdioCollector { }
    onExited: function(code) {
      if (code === 0 && root.selected) root.previewFile = previewProc.target
    }
  }

  // A render keeps running when you go back or close the panel — it copies and
  // notifies on its own.
  function backToSearch() {
    stage = "search"
    statusText = ""
    if (results.length > 0) focusGrid()
    else focusQuery()
  }

  function focusEditField(index) {
    editField = ((index % 4) + 4) % 4
    Qt.callLater(function() { if (root.focusItem) root.focusItem.forceActiveFocus() })
  }

  function setCaptionSize(value) {
    captionSize = Math.max(8, Math.min(200, value))
  }

  // Every control in the caption stage routes its keys here (attached with
  // Keys.priority BeforeItem), so Tab, Esc and the render shortcut behave the
  // same whether the caption box, the chips, the color or the size has focus.
  function editKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0

    // While the palette is up it owns the arrows, Enter and Esc.
    if (paletteOpen) {
      if (event.key === Qt.Key_Escape) paletteOpen = false
      else if (event.key === Qt.Key_Left) movePalette(-1)
      else if (event.key === Qt.Key_Right) movePalette(1)
      else if (event.key === Qt.Key_Up) movePalette(-paletteColumns)
      else if (event.key === Qt.Key_Down) movePalette(paletteColumns)
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
               || event.key === Qt.Key_Space) pickPalette(paletteIndex)
      else return
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Escape) {
      backToSearch()
    } else if (ctrl && (event.key === Qt.Key_R || event.key === Qt.Key_Return
                        || event.key === Qt.Key_Enter)) {
      render()
    } else if (editField === 2 && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
      togglePalette()
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      focusEditField(editField + (shift || event.key === Qt.Key_Backtab ? -1 : 1))
    } else if (ctrl && event.key === Qt.Key_1) {
      anchorMode = "top"
    } else if (ctrl && event.key === Qt.Key_2) {
      anchorMode = "middle"
    } else if (ctrl && event.key === Qt.Key_3) {
      anchorMode = "bottom"
    } else if (ctrl && (event.key === Qt.Key_Up || event.key === Qt.Key_Plus
                        || event.key === Qt.Key_Equal)) {
      setCaptionSize(captionSize + 2)
    } else if (ctrl && (event.key === Qt.Key_Down || event.key === Qt.Key_Minus)) {
      setCaptionSize(captionSize - 2)
    } else {
      return
    }
    event.accepted = true
  }

  function render() {
    if (!selected || rendering) return
    if (missingTools.length > 0) {
      statusText = "Install " + missingPackages.join(", ") + " first."
      return
    }
    var color = Model.normalizeHex(colorField.text)
    if (!color) { statusText = "Color must look like #ffee00."; return }
    captionColor = color
    rendering = true
    lastGif = ""
    lastMp4 = ""
    statusText = "Starting…"
    // One process: write the caption to a temp file (so no quoting of the
    // caption ever reaches ffmpeg), run the renderer, clean up.
    renderProc.command = ["sh", "-c",
      'tmp=$(mktemp -t gif-caption.XXXXXX) || exit 1; printf "%s" "$1" > "$tmp"; shift; ' +
      '"$@" --text-file "$tmp"; rc=$?; rm -f "$tmp"; exit $rc',
      "gif-captioner-render", caption,
      renderScript,
      "--url", String(selected.url),
      "--anchor", anchorMode,
      "--color", color,
      "--size", String(captionSize),
      "--copy-as", copyAs]
    renderProc.running = true
  }

  // ---- giphy key ----
  function saveKey() {
    var key = keyField.text.trim()
    if (key === "") return
    // Same reasoning as the search: the key travels in the environment, and the
    // file is written owner-only — it is a credential, not config.
    keyProc.environment = ({ "GIF_CAPTIONER_GIPHY_KEY": key })
    keyProc.command = ["sh", "-c",
      'umask 077; mkdir -p "$(dirname "$1")" ' +
      '&& printf "GIPHY_KEY=%s\\n" "$GIF_CAPTIONER_GIPHY_KEY" > "$1" && chmod 600 "$1"',
      "gif-captioner-key", keyFile]
    keyProc.running = true
    giphyKey = key
    stage = "search"
    statusText = "Key saved. Type a search and press Enter."
    focusQuery()
  }

  // Which caption control the keyboard is on. The kit's own focus tokens are
  // too quiet to follow at this size, and Tab-cycling is the point of the
  // caption stage, so the current field gets an unmistakable accent ring.
  component FocusRing: Rectangle {
    required property bool active
    anchors.fill: parent
    radius: Style.cornerRadius
    color: "transparent"
    border.width: Math.max(1, Style.space(2))
    border.color: Color.accent
    visible: active
  }

  FileView {
    path: root.keyFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.giphyKey = Model.parseKeyFile(text())
    onLoadFailed: root.giphyKey = ""
  }

  Process { id: keyProc }

  // Which of the render script's tools are actually installed.
  Process {
    id: toolsProc
    command: ["sh", "-c",
      'for tool in ffmpeg ffprobe curl wl-copy fc-match; do ' +
      '  command -v "$tool" >/dev/null 2>&1 || printf "%s\\n" "$tool"; done']
    stdout: StdioCollector {
      onStreamFinished: {
        var missing = String(text).trim()
        root.missingTools = missing === "" ? [] : missing.split("\n")
      }
    }
  }

  Process { id: copyCommandProc }

  Process {
    id: searchProc
    property int seq: 0
    property int offset: 0
    // Collected, not inherited: curl's stderr would otherwise land in the
    // shell's journal.
    stderr: StdioCollector { onStreamFinished: searchProc.errText = String(text).trim() }
    property string errText: ""
    stdout: StdioCollector {
      onStreamFinished: {
        if (searchProc.seq !== root.searchSeq) return   // a newer search won
        try {
          root.applyResults(Model.parseSearch(text), searchProc.offset)
        } catch (e) {
          root.searching = false
          root.statusText = "Giphy returned something unreadable."
        }
      }
    }
    onExited: function(code) {
      if (code === 0 || searchProc.seq !== root.searchSeq) return
      root.searching = false
      root.results = []
      root.statusText = "Search failed (curl exited " + code + "). Check the network or the key."
    }
  }

  Process {
    id: renderProc
    property string errText: ""
    stdout: SplitParser {
      onRead: function(line) {
        var text = String(line)
        if (text.indexOf("status: ") === 0) root.statusText = text.slice(8)
        else if (text.indexOf("gif: ") === 0) root.lastGif = text.slice(5)
        else if (text.indexOf("mp4: ") === 0) root.lastMp4 = text.slice(5)
      }
    }
    stderr: StdioCollector { onStreamFinished: renderProc.errText = String(text).trim() }
    onExited: function(code) {
      root.rendering = false
      if (code === 0) {
        // Rendered, copied, notification sent: the job is done, so get out of
        // the way. A failure keeps the panel open — that one you have to read.
        root.close()
        return
      }
      var tail = renderProc.errText.split("\n").slice(-2).join(" ")
      root.statusText = tail !== "" ? "Failed: " + tail : "Render failed (" + code + ")"
      renderProc.errText = ""
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF0D8C)   // nf-md-gif
    tooltipText: "Caption a GIF" + (root.shortcut !== "" ? " · " + root.shortcut : "")
    active: root.opened
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // The panel focuses this on open (and on every re-summon): whatever the
    // state we were left in types into.
    focusTarget: root.focusItem
    contentWidth: panel.fittedContentWidth(Style.space(420))
    // Exactly three rows of thumbnails plus the query field and the status
    // line, so the grid never slices a row in half. The caption stage inherits
    // the same height and gives whatever is left over to the preview.
    contentHeight: panel.fittedContentHeight(searchField.implicitHeight
      + Math.max(Style.space(80), grid.cellHeight) * root.visibleRows
      + depsBanner.height + searchFooter.height + Style.spacing.sm * 2)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Only the results grid is driven from here; text fields and the whole
      // caption stage own their own keys.
      blocked: root.stage !== "search" || root.fieldFocused || root.capturingShortcut
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: if (root.stage === "search") root.openEditor(root.cursor)
      onTabRequested: root.focusQuery()
      onTextKey: function(text) { root.gridTextKey(text) }

      // ---------------- missing tools ----------------
      // The render runs on ffmpeg, curl, wl-clipboard and fontconfig. If any of
      // them is absent, say so up front — with the command that fixes it —
      // rather than letting a render fail three clicks later.
      BorderSurface {
        id: depsBanner
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.missingTools.length > 0 || root.shortcutInvalid
          || root.shortcutTaken !== "" || root.bindError !== ""
        height: visible ? depsColumn.implicitHeight + Style.spacing.md * 2 : 0
        radius: Style.cornerRadius
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
        borderSpec: Border.controlSpec("normal", root.fg, Color.accent)

        Column {
          id: depsColumn
          anchors.centerIn: parent
          width: parent.width - Style.spacing.md * 2
          spacing: Style.spacing.xs

          Text {
            width: parent.width
            text: root.missingTools.length > 0
              ? "Needs " + root.missingPackages.join(", ")
              : root.shortcutInvalid
              ? "Shortcut “" + root.shortcut + "” is not a valid key combination"
              : root.shortcutTaken !== ""
              ? "“" + root.shortcut + "” is already bound to " + root.shortcutTaken
              : "Could not register the shortcut"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
          Text {
            width: parent.width
            text: root.missingTools.length > 0 ? root.installCommand
              : root.shortcutInvalid
              ? "Use modifier and key names, e.g. SUPER ALT G or CTRL SHIFT F9."
              : root.shortcutTaken !== ""
              ? "Pick a free combination in settings — Hyprland keeps the existing binding."
              : root.bindError
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Button {
            visible: root.missingTools.length > 0
            text: "Copy command"
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            bordered: true
            onClicked: {
              copyCommandProc.command = ["sh", "-c", 'printf "%s" "$1" | wl-copy',
                                         "gif-captioner-copy", root.installCommand]
              copyCommandProc.running = true
            }
          }
        }
      }

      // ---------------- search stage ----------------
      Item {
        id: searchView
        anchors.top: depsBanner.bottom
        anchors.topMargin: depsBanner.visible ? Style.spacing.md : 0
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.stage === "search"
        enabled: visible

        // Keys the fields inside don't consume bubble back up to here.
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (searchField.activeFocus && searchField.text !== "") searchField.text = ""
            else root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Comma && (event.modifiers & Qt.ControlModifier)) {
            root.openSettings()
            event.accepted = true
          }
        }

        // Query on the left, the gear that opens the settings page on the right.
        TextField {
          id: searchField
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: settingsButton.left
          anchors.rightMargin: Style.spacing.sm
          foreground: root.fg
          verticalPadding: Style.spacing.controlPaddingY
          placeholderText: "Search GIFs…"
          onAccepted: root.search(0)
          // Down and Tab step into the grid; taken before the field so Tab
          // never wanders off into Qt's own focus chain.
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
              root.focusGrid()
              event.accepted = true
            }
          }
        }

        Button {
          id: settingsButton
          anchors.top: parent.top
          anchors.right: parent.right
          height: searchField.height
          text: String.fromCodePoint(0xF0493)   // nf-md-cog
          tooltipText: "Settings — API key and shortcut"
          foreground: root.fg
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.openSettings()
        }

        // The box the grid may use; the grid itself takes a whole number of
        // rows out of it, so a row is never sliced against the status line.
        // (The panel's contentHeight is sized so that number is three.)
        Item {
          id: gridBox
          anchors.top: searchField.bottom
          anchors.topMargin: Style.spacing.sm
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: searchFooter.top
          anchors.bottomMargin: Style.spacing.sm
        }

        GridView {
          id: grid
          x: gridBox.x
          y: gridBox.y
          width: gridBox.width
          height: Math.max(cellHeight, Math.floor(gridBox.height / cellHeight) * cellHeight)
          clip: true
          cellWidth: Math.floor(width / root.columns)
          cellHeight: cellWidth
          boundsBehavior: Flickable.StopAtBounds
          model: root.results
          // Scrolling to the bottom pulls the next page in, same as walking
          // the cursor into the last row.
          onAtYEndChanged: if (atYEnd && root.hasMore && !root.searching) root.search(root.nextOffset)

          delegate: Item {
            id: cell
            required property int index
            required property var modelData
            readonly property bool current: cell.index === root.cursor

            width: grid.cellWidth
            height: grid.cellHeight

            // The cursor is an accent card *behind* the thumbnail, and every
            // other thumbnail is dimmed: a 2px outline alone disappears over
            // busy animated content.
            Rectangle {
              anchors.fill: parent
              anchors.margins: Style.spacing.xs
              radius: Style.cornerRadius
              color: cell.current ? Color.accent : "transparent"
              clip: true

              LoopingGif {
                anchors.fill: parent
                anchors.margins: cell.current ? Math.max(2, Style.space(3)) : 0
                source: cell.modelData.thumb
                wanted: root.opened && root.stage === "search"
                opacity: cell.current ? 1 : 0.68
                fillMode: Image.PreserveAspectCrop
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse) root.cursor = cell.index
              onClicked: root.openEditor(cell.index)
            }
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(20)
            visible: root.results.length === 0 && !root.searching && root.hasKey
            text: "Type a search and press Enter."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }

        // Persistent keys on the left, transient status and the cursor's
        // position in the results on the right.
        Item {
          id: searchFooter
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: searchHint.implicitHeight

          Text {
            id: searchHint
            anchors.left: parent.left
            anchors.right: searchCount.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusText !== "" ? root.statusText
                : root.searchFocus === "grid" ? "hjkl move · ↵ caption · n more · , settings"
                : "↵ search · ↓ results · ctrl+, settings · esc close"
            color: root.statusText !== "" ? Color.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: searchCount
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.results.length > 0
            text: (root.cursor + 1) + "/" + root.results.length + (root.hasMore ? "+" : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // ---------------- settings ----------------
      // The gear in the search bar lands here, and so does a first run with no
      // API key: the two things that need setting up, on one page.
      Item {
        id: settingsView
        anchors.top: depsBanner.bottom
        anchors.topMargin: depsBanner.visible ? Style.spacing.md : 0
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.stage === "settings"
        enabled: visible

        // Catch-all for anything the two controls below don't consume.
        Keys.onPressed: function(event) { root.settingsKey(event) }

        Column {
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.spacing.md

          PanelSectionHeader {
            width: parent.width
            text: "Giphy API key"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            text: root.hasKey
              ? "Stored in ~/.config/gif-captioner/config — the same file the gif-captioner "
                + "terminal app reads. Replace it here if you ever rotate the key."
              : "1. Open developers.giphy.com and sign up (free).\n"
                + "2. Create an App, pick the API (not SDK) option.\n"
                + "3. Copy the API key it shows and paste it below.\n\n"
                + "It is saved to ~/.config/gif-captioner/config. Nothing is sent anywhere else."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm
            TextField {
              id: keyField
              width: parent.width - saveKeyButton.width - dashboardButton.width
                - Style.spacing.sm * 2
              foreground: root.fg
              verticalPadding: Style.spacing.controlPaddingY
              placeholderText: "Paste the API key here"
              onAccepted: root.saveKey()
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) { root.settingsKey(event) }
              FocusRing { active: root.stage === "settings" && root.settingsField === 0 }
            }
            Button {
              id: saveKeyButton
              focusable: true
              text: "Save"
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: root.saveKey()
            }
            Button {
              id: dashboardButton
              focusable: true
              text: "Get a key"
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: Quickshell.execDetached(["xdg-open", "https://developers.giphy.com/dashboard/"])
            }
          }

          PanelSectionHeader {
            width: parent.width
            text: "Keyboard shortcut"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            text: "Opens this panel from anywhere. Registered with Hyprland while the "
                + "widget is enabled; nothing is written to your Hyprland config."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // One focus stop for the whole shortcut control: Enter starts
          // listening, the next combination you press becomes the shortcut,
          // Backspace clears it. Hyprland gets first refusal on key events, so
          // a combination already bound elsewhere never arrives here — pick a
          // free one.
          Item {
            id: shortcutRow
            width: parent.width
            height: shortcutButtons.height

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (root.capturingShortcut) {
                if (event.key === Qt.Key_Escape) {
                  root.capturingShortcut = false
                  event.accepted = true
                  return
                }
                var spec = root.shortcutFromEvent(event)
                event.accepted = true        // swallow everything while listening
                if (spec === "") return      // modifier-only press: keep waiting
                root.setShortcut(spec)
                root.capturingShortcut = false
                return
              }
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                  || event.key === Qt.Key_Space) {
                root.capturingShortcut = true
                event.accepted = true
              } else if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) {
                root.setShortcut("")
                event.accepted = true
              } else {
                root.settingsKey(event)
              }
            }

            Row {
              id: shortcutButtons
              spacing: Style.spacing.sm

              Button {
                id: captureButton
                text: root.capturingShortcut ? "Press a combination…"
                  : (root.shortcut !== "" ? root.shortcut : "Set shortcut")
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                selected: root.capturingShortcut
                onClicked: {
                  root.settingsField = 1
                  root.capturingShortcut = !root.capturingShortcut
                  root.restoreFocus()
                }
                FocusRing {
                  active: root.stage === "settings" && root.settingsField === 1
                    && !root.capturingShortcut
                }
              }

              Button {
                text: "None"
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                enabled: root.shortcut !== "" || root.capturingShortcut
                onClicked: {
                  root.settingsField = 1
                  root.capturingShortcut = false
                  root.setShortcut("")
                  root.restoreFocus()
                }
              }
            }
          }
        }

        // Footer: back out the way you came.
        Item {
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: settingsHint.implicitHeight

          Button {
            id: settingsBack
              focusable: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: root.hasKey
            text: "Back"
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            onClicked: root.backToSearch()
          }

          Text {
            id: settingsHint
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusText !== "" ? root.statusText
              : root.capturingShortcut ? "press the combination · esc cancels"
              : root.settingsField === 1 ? "↵ set shortcut · backspace clears · tab key · esc back"
              : (root.hasKey ? "tab shortcut · esc back" : "paste a key to start searching")
            color: root.statusText !== "" ? Color.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      // ---------------- caption stage ----------------
      Item {
        id: editView
        anchors.top: depsBanner.bottom
        anchors.topMargin: depsBanner.visible ? Style.spacing.md : 0
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.stage === "edit"
        enabled: visible

        // Catch-all for controls that don't take keys themselves (buttons).
        Keys.onPressed: function(event) { root.editKey(event) }

        // Colour palette, over the preview so it never resizes the panel.
        // Click the swatch, or press Enter on the colour field, to open it.
        BorderSurface {
          id: paletteBox
          visible: root.paletteOpen
          z: 10
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: controls.top
          anchors.bottomMargin: Style.spacing.sm
          height: paletteGrid.height + Style.spacing.md * 2
          radius: Style.cornerRadius
          color: Color.popups.background
          borderSpec: Border.controlSpec("normal", root.fg, Color.accent)

          MouseArea { anchors.fill: parent }   // clicks stay inside the palette

          Grid {
            id: paletteGrid
            anchors.centerIn: parent
            columns: root.paletteColumns
            spacing: Style.spacing.sm

            Repeater {
              model: root.palette

              Rectangle {
                required property int index
                required property string modelData
                readonly property bool current: root.paletteIndex === index

                width: Style.space(30)
                height: Style.space(24)
                radius: Math.max(1, Style.cornerRadius / 2)
                color: modelData
                border.width: current ? Math.max(2, Style.space(3)) : 1
                border.color: current ? Color.accent : Qt.rgba(1, 1, 1, 0.25)

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) root.paletteIndex = index
                  onClicked: root.pickPalette(index)
                }
              }
            }
          }
        }

        CaptionPreview {
          id: preview
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: metaLine.top
          anchors.bottomMargin: Style.spacing.sm
          // The local copy once it is there, the thumbnail meanwhile.
          source: root.previewFile !== "" ? "file://" + root.previewFile
                : (root.selected ? String(root.selected.thumb) : "")
          caption: root.caption
          anchorMode: root.anchorMode
          captionColor: root.captionColor
          captionSize: root.captionSize
          outWidth: root.outSize.width
          outHeight: root.outSize.height
          playing: root.opened && root.stage === "edit"
        }

        // Which GIF this is and what will come out of the render.
        Text {
          id: metaLine
          anchors.bottom: controls.top
          anchors.bottomMargin: Style.spacing.sm
          anchors.left: parent.left
          anchors.right: parent.right
          text: (root.selected ? root.selected.title : "")
            + " · " + root.outSize.width + "×" + root.outSize.height
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Column {
          id: controls
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.spacing.sm

          QQC.TextArea {
            id: captionField
            width: parent.width
            placeholderText: "Caption · ctrl+↵ to render"
            color: root.fg
            placeholderTextColor: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: TextEdit.Wrap
            topPadding: Style.spacing.controlPaddingY
            bottomPadding: Style.spacing.controlPaddingY
            selectionColor: Style.selectionFillFor(root.fg, Color.accent)
            selectedTextColor: root.fg
            onTextChanged: root.caption = text
            // Before the text area itself: Tab must cycle the caption controls
            // instead of inserting a tab, and Ctrl+Enter must render instead of
            // adding a line.
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) { root.editKey(event) }
            background: BorderSurface {
              color: Style.controlFill(captionField.activeFocus, captionField.hovered, root.fg, Color.accent)
              borderSpec: Border.controlSpec(captionField.activeFocus ? "focus"
                : (captionField.hovered ? "hover-cursor" : "normal"), root.fg, Color.accent)
              radius: Style.cornerRadius
              FocusRing { active: root.stage === "edit" && root.editField === 0 }
            }
          }

          // Position · color · size, one row, all three reachable with Tab.
          Row {
            width: parent.width
            spacing: Style.spacing.sm

            // Wrapper so the focus ring can sit over the whole chip group
            // without becoming another item inside the row.
            Item {
              anchors.verticalCenter: parent.verticalCenter
              width: anchorGroup.width
              height: anchorGroup.height
              FocusRing { active: root.stage === "edit" && root.editField === 1
                         anchors.margins: -Style.spacing.xs }

            ButtonGroup {
              id: anchorGroup
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              spacing: Style.spacing.xs
              options: [ { value: "top", label: "Top", tooltip: "ctrl+1" },
                         { value: "middle", label: "Mid", tooltip: "ctrl+2" },
                         { value: "bottom", label: "Bottom", tooltip: "ctrl+3" } ]
              value: root.anchorMode
              // Paint the active chip with the cursor state too: the selected
              // fill alone is nearly invisible at this size.
              cursorIndex: activeFocus ? -1 : selectedOptionIndex()
              onChanged: function(value) { root.anchorMode = value }
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) { root.editKey(event) }
            }
            }

            // The colour, as itself — and the way into the palette.
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.spacing.controlHeight - Style.spacing.xs * 2
              height: width
              radius: Math.max(1, Style.cornerRadius / 2)
              color: root.captionColor
              border.width: root.paletteOpen ? Math.max(1, Style.space(2)) : 1
              border.color: root.paletteOpen ? Color.accent : Qt.rgba(1, 1, 1, 0.35)

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.spacing.xs
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.editField = 2
                  root.togglePalette()
                }
              }
            }

            TextField {
              id: colorField
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(84)
              foreground: root.fg
              font.pixelSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              text: root.captionColor
              placeholderText: "#ffffff"
              // Live: every complete hex updates the preview, so the field and
              // the picture never disagree.
              onTextChanged: {
                var hex = Model.normalizeHex(text)
                if (hex) root.captionColor = hex
              }
              onEditingFinished: text = root.captionColor
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) { root.editKey(event) }
              FocusRing { active: root.stage === "edit" && root.editField === 2 }
            }

            // Compact stepper instead of a spin box: the kit has no themed
            // number input, and a raw QQC SpinBox is the one control that does
            // not look like the rest of the panel.
            BorderSurface {
              id: sizeField
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(84)
              height: Style.spacing.controlHeight
              radius: Style.cornerRadius
              color: Style.controlFill(activeFocus, sizeHover.containsMouse, root.fg, Color.accent)
              borderSpec: Border.controlSpec(activeFocus ? "focus"
                : (sizeHover.containsMouse ? "hover-cursor" : "normal"), root.fg, Color.accent)

              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Left || event.key === Qt.Key_Down
                    || event.text === "h" || event.text === "j") {
                  root.setCaptionSize(root.captionSize - 2)
                  event.accepted = true
                } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Up
                    || event.text === "l" || event.text === "k") {
                  root.setCaptionSize(root.captionSize + 2)
                  event.accepted = true
                } else {
                  root.editKey(event)
                }
              }

              FocusRing { active: root.stage === "edit" && root.editField === 3 }

              MouseArea {
                id: sizeHover
                anchors.fill: parent
                hoverEnabled: true
                onWheel: function(wheel) {
                  root.setCaptionSize(root.captionSize + (wheel.angleDelta.y > 0 ? 2 : -2))
                }
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                text: "−"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.spacing.xs
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setCaptionSize(root.captionSize - 2)
                }
              }
              Text {
                anchors.centerIn: parent
                text: root.captionSize + "px"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                text: "+"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.spacing.xs
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setCaptionSize(root.captionSize + 2)
                }
              }
            }
          }

          // The primary action stays clickable, but the keys are the point:
          // the line next to it is the hint until something happens, then the
          // renderer's own progress in the accent colour.
          Item {
            width: parent.width
            height: renderButton.implicitHeight

            Button {
              id: renderButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.rendering ? "Rendering…" : "Render & copy"
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              enabled: !root.rendering
              onClicked: root.render()
            }

            Text {
              anchors.left: renderButton.right
              anchors.leftMargin: Style.spacing.md
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.statusText !== "" ? root.statusText
                                           : "tab fields · esc back"
              color: root.statusText !== "" ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideLeft
            }
          }
        }
      }
    }
  }
}
