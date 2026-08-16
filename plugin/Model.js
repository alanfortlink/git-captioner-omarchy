.pragma library

// Giphy plumbing and the geometry both the preview and the render script agree
// on. Ported from the other two gif-captioner apps (src/giphy.rs,
// webapp/lib/services/giphy.dart) so all three pick the same URLs and sizes.

var PAGE_SIZE = 25
var MAX_WIDTH = 360          // must match bin/gif-captioner-render
var ENDPOINT = "https://api.giphy.com/v1/gifs/search"

// The query itself is assembled by curl (--get --data-urlencode) so the API key
// travels in the environment instead of on a world-readable command line; see
// Panel.qml's search().

// Same preference order as the Rust and Flutter clients: a small still-animated
// variant for the grid, the original for the render.
function pickThumb(images) {
  var keys = ["fixed_width_small", "fixed_width_downsampled", "preview_gif", "fixed_width"]
  for (var i = 0; i < keys.length; i++) {
    var entry = images[keys[i]]
    if (entry && entry.url) return entry.url
  }
  return ""
}

function dim(value) {
  var n = parseInt(value, 10)
  return isFinite(n) && n > 0 ? n : 0
}

function parseSearch(raw) {
  var body = JSON.parse(String(raw || ""))
  var data = (body && body.data) || []
  var out = []
  for (var i = 0; i < data.length; i++) {
    var item = data[i] || {}
    var images = item.images || {}
    var original = images.original || {}
    if (!original.url) continue
    out.push({
      id: String(item.id || ""),
      title: String(item.title || item.slug || "(untitled)"),
      url: String(original.url),
      thumb: String(pickThumb(images) || original.url),
      width: dim(original.width),
      height: dim(original.height)
    })
  }
  return out
}

// What the render script will produce: width capped at MAX_WIDTH, both sides
// even (the MP4 encode needs it). The preview scales the caption by
// previewWidth / out.width so what you see is what gets burned in.
function outputSize(width, height) {
  var w = width > 0 ? width : MAX_WIDTH
  var h = height > 0 ? height : MAX_WIDTH
  var outW = Math.min(MAX_WIDTH, w)
  var outH = Math.round(h * outW / w)
  outW -= outW % 2
  outH -= outH % 2
  return { width: Math.max(2, outW), height: Math.max(2, outH) }
}

// "#rgb" / "rrggbb" / "#rrggbb" -> "#rrggbb"; anything else -> null.
function normalizeHex(text) {
  var hex = String(text || "").trim().replace(/^#/, "").toLowerCase()
  if (/^[0-9a-f]{3}$/.test(hex))
    hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]
  return /^[0-9a-f]{6}$/.test(hex) ? "#" + hex : null
}

// GIPHY_KEY=… out of ~/.config/gif-captioner/config (the file the Rust TUI
// uses, so both read one key).
function parseKeyFile(text) {
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*(?:GIPHY_KEY|TENOR_KEY)\s*=\s*(.+?)\s*$/)
    if (match) return match[1]
  }
  return ""
}
