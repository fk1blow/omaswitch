var maxDisplayLength = 160

function boundedText(value) {
  value = String(value || "")
  return value.length > maxDisplayLength ? value.slice(0, maxDisplayLength - 1) + "…" : value
}

function appId(window) {
  if (!window) return ""
  if (window.wayland && window.wayland.appId) return String(window.wayland.appId)
  var ipc = window.lastIpcObject || {}
  return String(ipc.class || ipc.initialClass || "")
}

function normalized(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "")
}

// "com.mitchellh.ghostty" -> "Ghostty", "google-chrome" -> "Google chrome".
function prettyAppId(window) {
  var id = appId(window)
  if (!id) return ""
  var last = String(id).split(".").pop().replace(/[-_]+/g, " ").trim()
  if (!last) return ""
  return last.charAt(0).toUpperCase() + last.slice(1)
}

var titleSeparators = [" — ", " – ", " - ", " | "]

// Window titles usually end with the application's own name: "Report — Mozilla
// Firefox", "inbox - Google Chrome". Showing that in the first row and the app
// id in the second says the same thing twice, so the suffix is split off the
// title and becomes the second row.
//
// The suffix is only stripped when it really is the application's name -
// compared against the app id, and against the desktop entry's name when the
// switcher resolved one, with punctuation and case removed - so a title that
// merely contains a dash ("Bug 123 - fix the parser") is left intact.
//
// Chromium web apps put the name at the FRONT instead ("(26) Discord |
// Friends"), and their class ("chrome-discord.com__channels_@me-Default")
// tokenizes to nothing that appears in the title, so the leading segment is
// tried too. For those windows the desktop entry name is the only token that
// can ever match, which is why it is passed in.
//
// Tokens shorter than three characters are dropped: substring matching against
// "x" or "hey" hits inside half the words on screen.
function appTokens(window, appName) {
  var tokens = []
  var idToken = normalized(String(appId(window)).split(".").pop())
  if (idToken.length >= 3) tokens.push(idToken)
  var nameToken = normalized(appName)
  if (nameToken.length >= 3 && tokens.indexOf(nameToken) === -1) tokens.push(nameToken)
  return tokens
}

function isAppSegment(segment, tokens) {
  var token = normalized(segment)
  if (token.length < 3) return false
  for (var i = 0; i < tokens.length; i++)
    if (token.indexOf(tokens[i]) !== -1 || tokens[i].indexOf(token) !== -1) return true
  return false
}

function splitTitle(window, appName) {
  var title = String((window && window.title) || "")
  var result = { name: title, app: "" }
  var tokens = appTokens(window, appName)
  if (!title || tokens.length === 0) return result

  for (var i = 0; i < titleSeparators.length; i++) {
    var separator = titleSeparators[i]

    // "Report - Mozilla Firefox": the name trails.
    var last = title.lastIndexOf(separator)
    if (last > 0) {
      var head = title.slice(0, last).trim()
      var tail = title.slice(last + separator.length).trim()
      if (head && tail && tail.length <= 40 && isAppSegment(tail, tokens)) {
        result.name = head
        result.app = tail
        return result
      }
    }

    // "(26) Discord | Friends": the name leads.
    var first = title.indexOf(separator)
    if (first > 0) {
      var lead = title.slice(0, first).trim()
      var rest = title.slice(first + separator.length).trim()
      if (lead && rest && lead.length <= 40 && isAppSegment(lead, tokens)) {
        result.name = rest
        result.app = lead
        return result
      }
    }
  }
  return result
}

function label(window, appName) {
  var parts = splitTitle(window, appName)
  return boundedText(parts.name || appName || prettyAppId(window) || "Untitled")
}

// Row two is the application's own name. The desktop entry's Name wins when
// the switcher resolved one - it is the only thing that names a Chromium web
// app, whose class is a mangled URL - then the suffix split off the title, then
// the app id. Blank when it would only repeat row one: "Steam / Steam" is noise.
function detail(window, appName) {
  if (!window) return ""
  var parts = splitTitle(window, appName)
  var value = boundedText(String(appName || "") || parts.app || prettyAppId(window))
  if (normalized(value) && normalized(value) === normalized(label(window, appName))) return ""
  return value
}

// A workspace number on every row is noise: most windows sit on the one you are
// already on. What matters is whether picking this window will move you off it,
// so the workspace is reported only when it differs from the current one.
function workspaceHint(window, currentWorkspaceId) {
  if (!window || !window.workspace) return ""
  var id = Number(window.workspace.id)
  if (!isFinite(id)) return ""
  var current = Number(currentWorkspaceId)
  if (isFinite(current) && id === current) return ""
  return "→ " + String(id)
}

// Hyprland's focusHistoryID is a rank in the compositor's global focus-history
// list: 0 = currently focused, 1 = most recent before that, ascending = older.
// Transient/popup windows not meaningfully in that history can report null or
// an empty string. Number(null) === 0 and Number("") === 0, so we must guard
// before coercion — otherwise such windows are ranked 0 (treated as current)
// and surface above genuinely recent ones.
function historyRank(window) {
  var ipc = window && window.lastIpcObject ? window.lastIpcObject : {}
  var raw = ipc.focusHistoryID
  if (raw === null || raw === undefined) return 1000000
  // "" and " " both coerce to 0; discard empty/whitespace values (transient
  // windows not meaningfully in the focus history).
  if (typeof raw !== "number" && String(raw).trim() === "") return 1000000
  var rank = Number(raw)
  return isFinite(rank) && rank >= 0 ? rank : 1000000
}

function isCurrent(window) {
  return !!(window && window.activated) || historyRank(window) === 0
}

function focusRank(window) {
  return isCurrent(window) ? -1 : historyRank(window)
}

// Quickshell's toplevel list also carries Wayland toplevels that have no
// Hyprland client behind them: Steam's hidden helpers ("steamwebhelper",
// "Steam SDL Dummy OpenGL Window", "VRStream"), IME surfaces ("Default IME",
// "Input") and other never-mapped surfaces. They have no address, no
// workspace and no class, so they cannot be focused - listing them just adds
// dead rows. Keep only toplevels that map to a real, mapped Hyprland window.
function isRealWindow(window) {
  if (!window) return false
  var raw = window.address
  if (raw === null || raw === undefined || String(raw).trim() === "") return false
  if (!window.workspace) return false
  var ipc = window.lastIpcObject || {}
  if (ipc.mapped === false) return false
  if (ipc.hidden === true) return false
  return true
}

function sortedWindows(values) {
  var source = values && typeof values.slice === "function" ? values.slice() : []
  source = source.filter(isRealWindow)
  var decorated = []
  for (var i = 0; i < source.length; i++) decorated.push({ value: source[i], index: i })
  decorated.sort(function(left, right) {
    return focusRank(left.value) - focusRank(right.value) || left.index - right.index
  })
  var result = []
  for (var j = 0; j < decorated.length; j++) result.push(decorated[j].value)
  return result
}

function filteredWindows(values, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return values.slice()
  return values.filter(function(window) {
    return (label(window) + " " + detail(window)).toLowerCase().indexOf(q) !== -1
  })
}

// Which window is under a screen point?
//
// Needed because Hyprland emits NO focus event when a window is clicked while
// a layer holds exclusive keyboard focus - verified across nine switcher
// sessions in the shell log - so an overlay cannot be told that the user
// clicked past it. It has to consume the click and work out the target itself.
//
// Candidates are limited to the workspace on screen. Overlapping floating
// windows tie-break by focus history: the most recently focused is the one
// drawn on top, which is the one the user sees and means.
function windowAt(windows, x, y, workspaceId) {
  var list = windows || []
  var best = null
  var bestRank = Infinity
  for (var i = 0; i < list.length; i++) {
    var window = list[i]
    if (!isRealWindow(window)) continue
    if (workspaceId !== undefined && workspaceId !== null && workspaceId >= 0 &&
        window.workspace && Number(window.workspace.id) !== Number(workspaceId)) continue
    var ipc = window.lastIpcObject || {}
    var at = ipc.at
    var size = ipc.size
    if (!at || !size || at.length < 2 || size.length < 2) continue
    var left = Number(at[0])
    var top = Number(at[1])
    var right = left + Number(size[0])
    var bottom = top + Number(size[1])
    if (!(x >= left && x < right && y >= top && y < bottom)) continue
    var rank = historyRank(window)
    if (rank < bestRank) {
      bestRank = rank
      best = window
    }
  }
  return best
}

// Build the shell command that focuses a window, moves to its workspace and
// raises it above its siblings. Native toplevel activate does not always
// switch the visible workspace, and focusing alone leaves a floating window
// underneath the stack, so both steps are dispatched explicitly.
//
// Omarchy 4 / Hyprland's Lua binds only accept the hl.dsp form and reject the
// legacy "focuswindow address:0x..." syntax with a non-zero exit, so the Lua
// form runs first and the legacy syntax is the fallback for stock Hyprland.
// Returns null when the window has no address, deferring to the native
// activate path in Switcher.qml.
function focusCommand(window) {
  var raw = window && window.address
  if (raw === null || raw === undefined || raw === "") return null
  var rawAddress = String(raw)
  var address = rawAddress.indexOf("0x") === 0 ? rawAddress : "0x" + rawAddress
  var target = "'address:" + address + "'"
  var lua = "hyprctl dispatch \"hl.dsp.focus({ window = " + target + " })\" && " +
    "hyprctl dispatch \"hl.dsp.window.bring_to_top({ window = " + target + " })\""
  var legacy = "hyprctl dispatch focuswindow \"address:" + address + "\" && " +
    "hyprctl dispatch alterzorder \"top,address:" + address + "\""
  return "{ " + lua + " ; } >/dev/null 2>&1 || { " + legacy + " ; } >/dev/null 2>&1"
}

// ---------------------------------------------------------------------------
// Reducing an app id to something a desktop entry can be found under.
//
// A Wayland app id is SUPPOSED to be the entry id. In practice it is whatever
// the toolkit felt like emitting:
//
//   firefox                                    the entry id, as promised
//   com.transmissionbt.transmission_58_931770  GTK appends an instance suffix
//   org.gnome.Nautilus                         reverse-DNS; the entry is nautilus
//   chrome-discord.com__channels_@me-Default   Chromium mangles the --app= URL
//
// These are pure string reductions and live here rather than in Switcher.qml so
// they can be tested: this is the part that grows every time a toolkit invents
// a new way to spell a name, and it is the part nothing else can check.
// ---------------------------------------------------------------------------

// Toolkit and packaging suffixes that turn up on one side of a match and not
// the other: the entry is transmission-gtk, the window says transmission.
var variantSuffix = /-(gtk[0-9]*|qt[0-9]*|x11|wayland|bin|git|stable|beta|nightly|dev|desktop|app)$/
// GTK's per-instance suffix: com.transmissionbt.transmission_58_931770.
var instanceSuffix = /([._-]\d+)+$/

// The comparison form for every key and every candidate. Case and punctuation
// carry no information here, and dropping them is what makes "transmission-gtk",
// "Transmission GTK" and "transmissiongtk" one key.
function flatten(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "")
}

// "org.gnome.Nautilus" -> "Nautilus". Empty when there is nothing to strip.
function dotTail(value) {
  var parts = String(value || "").split(".")
  return parts.length > 1 ? parts[parts.length - 1] : ""
}

function stripVariant(value) {
  return String(value || "").replace(variantSuffix, "")
}

// "transmission-gtk %U" -> "transmission-gtk", "/usr/bin/foo --bar" -> "foo".
function execProgram(exec) {
  var first = String(exec || "").trim().split(/\s+/)[0] || ""
  var slash = first.lastIndexOf("/")
  return slash >= 0 ? first.slice(slash + 1) : first
}

// The flattened host and path of the URL an Exec= line opens, or "" when it
// opens no URL. Chromium builds a --app= window's class out of exactly this, so
// it is what a web app is looked up under.
function execUrlKey(exec) {
  var url = String(exec || "").match(/https?:\/\/[^\s"']+/)
  if (!url) return ""
  var key = flatten(url[0].replace(/^https?:\/\//i, ""))
  return key.length >= 4 ? key : ""
}

// The flattened spellings of one app id worth looking up, most faithful first:
//
//   com.transmissionbt.transmission_58_931770   as reported
//   com.transmissionbt.transmission             minus the instance suffix
//   transmission                                minus the reverse-DNS prefix
//   transmission                                minus a toolkit suffix
//
// Anything under three characters is dropped: at that length a key collides
// more often than it identifies.
function appIdCandidates(id) {
  var out = []
  var push = function(value) {
    var key = flatten(value)
    if (key.length >= 3 && out.indexOf(key) === -1) out.push(key)
  }
  var raw = String(id || "").trim()
  var stripped = raw.replace(instanceSuffix, "")
  var tail = dotTail(stripped)
  push(raw)
  push(stripped)
  push(tail)
  push(stripVariant(tail || stripped))
  return out
}

// The same reduction for ICON names, which keep their punctuation - an icon
// really is installed as "com.mitchellh.ghostty.png". Used when an app ships an
// icon named after its own class and no desktop entry at all.
function iconNameCandidates(id) {
  var out = []
  var push = function(value) {
    var name = String(value || "").trim()
    if (name && out.indexOf(name) === -1) out.push(name)
  }
  var raw = String(id || "").trim()
  var stripped = raw.replace(instanceSuffix, "")
  var tail = dotTail(stripped)
  push(raw)
  push(stripped)
  push(tail)
  push(stripVariant(tail || stripped))
  return out
}

if (typeof module !== "undefined") module.exports = {
  appId: appId,
  label: label,
  detail: detail,
  workspaceHint: workspaceHint,
  splitTitle: splitTitle,
  prettyAppId: prettyAppId,
  isCurrent: isCurrent,
  isRealWindow: isRealWindow,
  windowAt: windowAt,
  sortedWindows: sortedWindows,
  filteredWindows: filteredWindows,
  focusCommand: focusCommand,
  flatten: flatten,
  dotTail: dotTail,
  stripVariant: stripVariant,
  execProgram: execProgram,
  execUrlKey: execUrlKey,
  appIdCandidates: appIdCandidates,
  iconNameCandidates: iconNameCandidates
}
