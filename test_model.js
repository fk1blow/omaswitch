const assert = require("node:assert/strict")
const Model = require("./Model.js")

const active = { title: "Browser", address: "0xa1", activated: true, wayland: { appId: "chromium" }, workspace: { id: 1 }, lastIpcObject: { focusHistoryID: 0 } }
const previous = { title: "Terminal", address: "0xa2", activated: false, wayland: { appId: "foot" }, workspace: { id: 2 }, lastIpcObject: { focusHistoryID: 1 } }
const old = { title: "Notes", address: "0xa3", activated: false, lastIpcObject: { class: "obsidian", focusHistoryID: 8 }, workspace: { id: 3 } }

assert.deepEqual(Model.sortedWindows([old, previous, active]), [active, previous, old])
assert.equal(Model.isCurrent(active), true)
assert.equal(Model.isCurrent({ activated: false, lastIpcObject: { focusHistoryID: 0 } }), true)
assert.deepEqual(Model.filteredWindows([active, previous, old], "foot"), [previous])
assert.deepEqual(Model.filteredWindows([active, previous, old], "notes"), [old])
assert.equal(Model.detail(old), "Obsidian")
assert.equal(Model.label({ title: "x".repeat(161) }), "x".repeat(159) + "…")
assert.equal(Model.detail({ title: "Session", wayland: { appId: "x".repeat(161) } }), "X" + "x".repeat(158) + "…")

// --- the two text rows ---
// Row one is the window, row two is the application. Three things decide them:
// where the app name sits in the title, whether a desktop entry named the app,
// and whether the two rows would end up saying the same thing.

// Trailing app name, the common case - unchanged by the app-name parameter.
const ffTitle = { title: "Babel (2006) - IMDb — Mozilla Firefox", wayland: { appId: "firefox" } }
assert.equal(Model.label(ffTitle), "Babel (2006) - IMDb")
assert.equal(Model.detail(ffTitle), "Mozilla Firefox")
assert.equal(Model.detail(ffTitle, "Firefox"), "Firefox")

// Chromium web app: the class is a mangled URL, so without the desktop entry
// name there is no token in common with the title and nothing can be split.
const discord = { title: "(26) Discord | Friends", wayland: { appId: "chrome-discord.com__channels_@me-Default" } }
assert.equal(Model.label(discord), "(26) Discord | Friends")
// With it, the LEADING segment is recognised as the app name and moves to row two.
assert.equal(Model.label(discord, "Discord"), "Friends")
assert.equal(Model.detail(discord, "Discord"), "Discord")

// A dash in a title is not an app name.
const bug = { title: "Bug 123 - fix the parser", wayland: { appId: "firefox" } }
assert.equal(Model.label(bug, "Firefox"), "Bug 123 - fix the parser")
assert.equal(Model.detail(bug, "Firefox"), "Firefox")

// Row two is dropped when it would only repeat row one.
const steam = { title: "Steam", wayland: { appId: "steam" } }
assert.equal(Model.label(steam, "Steam"), "Steam")
assert.equal(Model.detail(steam, "Steam"), "")

// Tokens under three characters are never matched: "x" appears inside "Firefox".
const shortName = { title: "Timeline - Home", wayland: { appId: "chrome-x.com__-Default" } }
assert.equal(Model.label(shortName, "X"), "Timeline - Home")
assert.equal(Model.detail(shortName, "X"), "X")

// --- reducing an app id to something a desktop entry can be found under ---
// The four classes that motivated the reduction, each with the spelling that has
// to come out of it for the lookup in Switcher.qml to land.

// Already the entry id: nothing to reduce, and no empty or duplicate candidates.
assert.deepEqual(Model.appIdCandidates("firefox"), ["firefox"])

// GTK's per-instance suffix, then the reverse-DNS prefix.
assert.deepEqual(
  Model.appIdCandidates("com.transmissionbt.transmission_58_931770"),
  ["comtransmissionbttransmission58931770", "comtransmissionbttransmission", "transmission"])

// Reverse-DNS alone. "org.gnome.Nautilus" must reach the entry id "nautilus".
assert.ok(Model.appIdCandidates("org.gnome.Nautilus").indexOf("nautilus") !== -1)

// A toolkit suffix on the window side rather than the entry side.
assert.ok(Model.appIdCandidates("foo-qt6").indexOf("foo") !== -1)

// Under three characters is dropped rather than offered as a candidate.
assert.deepEqual(Model.appIdCandidates("qb"), [])
assert.deepEqual(Model.appIdCandidates(""), [])

// Icon names keep their punctuation - the file really is com.mitchellh.ghostty.png.
assert.deepEqual(
  Model.iconNameCandidates("com.mitchellh.ghostty"),
  ["com.mitchellh.ghostty", "ghostty"])
assert.deepEqual(
  Model.iconNameCandidates("com.transmissionbt.transmission_58_931770"),
  ["com.transmissionbt.transmission_58_931770", "com.transmissionbt.transmission", "transmission"])

assert.equal(Model.flatten("Transmission-GTK"), "transmissiongtk")
assert.equal(Model.dotTail("org.gnome.Nautilus"), "Nautilus")
assert.equal(Model.dotTail("firefox"), "")
assert.equal(Model.stripVariant("transmission-gtk"), "transmission")
assert.equal(Model.stripVariant("firefox"), "firefox")

// Exec= is a command line, not a program name.
assert.equal(Model.execProgram("transmission-gtk %U"), "transmission-gtk")
assert.equal(Model.execProgram("/usr/bin/steam-runtime %U"), "steam-runtime")
assert.equal(Model.execProgram(""), "")

// A web app is looked up under the URL its Exec= opens, flattened the same way
// Chromium flattens it into the window class.
assert.equal(
  Model.execUrlKey("omarchy-launch-webapp https://discord.com/channels/@me"),
  "discordcomchannelsme")
// ... and that key is a PREFIX of the class Chromium then produces.
assert.equal(
  Model.flatten("discord.com__channels_@me-Default")
    .indexOf(Model.execUrlKey("omarchy-launch-webapp https://discord.com/channels/@me")),
  0)
// Entries that open no URL contribute no web-app key.
assert.equal(Model.execUrlKey("transmission-gtk %U"), "")

// --- focusCommand: switching to windows on other workspaces ---
// Reproduces the bug: confirming a selection previously used the native
// activate path, which focuses the window but does NOT move to its workspace,
// and the plain `focuswindow` fallback dropped the 0x address prefix, so the
// lookup silently missed. Verifies the fix always dispatches an explicit,
// workspace-switching command.
const target = { title: "Browser", address: "55ea685ceda0", workspace: { id: 5 } }
const targetHex = { title: "Browser", address: "0x55ea685ceda0", workspace: { id: 5 } }
const expected = "{ hyprctl dispatch \"hl.dsp.focus({ window = 'address:0x55ea685ceda0' })\" && " +
  "hyprctl dispatch \"hl.dsp.window.bring_to_top({ window = 'address:0x55ea685ceda0' })\" ; } >/dev/null 2>&1 || " +
  "{ hyprctl dispatch focuswindow \"address:0x55ea685ceda0\" && " +
  "hyprctl dispatch alterzorder \"top,address:0x55ea685ceda0\" ; } >/dev/null 2>&1"

assert.ok(Model.focusCommand(target), "window with address must produce a dispatch command")
assert.equal(Model.focusCommand(target), expected, "address must be normalized with 0x prefix")
assert.equal(Model.focusCommand(targetHex), expected, "existing 0x prefix must be preserved")
assert.ok(Model.focusCommand(target).indexOf("hl.dsp.focus(") !== -1,
  "primary dispatch must be the workspace-switching hl.dsp.focus form")
assert.ok(Model.focusCommand(target).indexOf("hl.dsp.window.bring_to_top(") !== -1,
  "focusing alone does not raise the window; the selection must be brought to the top")
assert.ok(Model.focusCommand(target).includes("|| { hyprctl dispatch focuswindow \"address:0x55ea685ceda0\""),
  "plain focuswindow must remain as the stock-Hyprland fallback")
assert.equal(Model.focusCommand({}), null, "no address defers to native activate fallback")
assert.equal(Model.focusCommand(null), null, "no window defers to native activate fallback")
console.log("Model checks passed")

// --- MRU ordering: unranked windows (no meaningful focusHistoryID) ---
// Hyprland reports focusHistoryID: null / "" for windows not meaningfully in
// the focus history (transient/popup clients). Number(null) === 0 and
// Number("") === 0, so the old historyRank() wrongly ranked them as the
// current window (rank 0), surfacing stale windows above genuinely recent
// ones and mislabeling them as current. They must sort AFTER all ranked
// windows, in source order, and never be treated as current.
const editorCur = { address: "0xeditorcur", workspace: { id: 1 }, title: "Editor", activated: true, lastIpcObject: { focusHistoryID: 0 }, wayland: { appId: "ed" } }
const termPrev = { address: "0xtermprev", workspace: { id: 1 }, title: "Term", activated: false, lastIpcObject: { focusHistoryID: 1 }, wayland: { appId: "foot" } }
const staleNull = { address: "0xstalenull", workspace: { id: 1 }, title: "StalePopup", activated: false, lastIpcObject: { focusHistoryID: null }, wayland: { appId: "popup" } }
const staleEmpty = { address: "0xstaleempty", workspace: { id: 1 }, title: "Mystery", activated: false, lastIpcObject: { focusHistoryID: "" }, wayland: { appId: "unknown" } }
const staleBlank = { address: "0xstaleblank", workspace: { id: 1 }, title: "Blank", activated: false, lastIpcObject: { focusHistoryID: " " }, wayland: { appId: "blank" } }

assert.deepEqual(
  Model.sortedWindows([termPrev, editorCur, staleNull, staleEmpty, staleBlank]).map(function(w) { return w.title }),
  ["Editor", "Term", "StalePopup", "Mystery", "Blank"],
  "unranked windows must sort AFTER ranked ones, in source order"
)

assert.equal(Model.isCurrent(staleNull), false, "null focusHistoryID must not be current")
assert.equal(Model.isCurrent(staleEmpty), false, "empty focusHistoryID must not be current")
assert.equal(Model.isCurrent({ activated: false, lastIpcObject: {} }), false, "missing focusHistoryID must not be current")
assert.equal(Model.isCurrent(editorCur), true, "activated window must be current")
assert.equal(Model.isCurrent({ activated: false, lastIpcObject: { focusHistoryID: 0 } }), true, "real rank 0 must be current")

// --- non-window toplevels ---
// Quickshell's toplevel list carries Wayland toplevels with no Hyprland client
// behind them (Steam's hidden helpers, IME surfaces). They have no address and
// no workspace, cannot be focused, and must never reach the list.
const ime = { title: "Default IME" }
const steamHelper = { title: "steamwebhelper", address: "" }
const unmapped = { title: "Hidden", address: "0xb1", workspace: { id: 1 }, lastIpcObject: { mapped: false } }
const hidden = { title: "Hidden", address: "0xb2", workspace: { id: 1 }, lastIpcObject: { hidden: true } }

assert.equal(Model.isRealWindow(ime), false, "a toplevel with no address is not a window")
assert.equal(Model.isRealWindow(steamHelper), false, "an empty address is not a window")
assert.equal(Model.isRealWindow(unmapped), false, "an unmapped client is not selectable")
assert.equal(Model.isRealWindow(hidden), false, "a hidden client is not selectable")
assert.equal(Model.isRealWindow(active), true, "a real window survives the filter")
assert.deepEqual(
  Model.sortedWindows([ime, active, steamHelper, previous]).map(function(w) { return w.title }),
  ["Browser", "Terminal"],
  "non-window toplevels must be dropped from the list"
)

// --- title / app split ---
// The app name appears in the window title AND in the app id; showing both is
// redundant, so the title's trailing app name becomes the second row.
const firefox = { title: "(2) WhatsApp — Mozilla Firefox", address: "0xc1", workspace: { id: 2 }, wayland: { appId: "firefox" } }
const chrome = { title: "inbox - Google Chrome", address: "0xc2", workspace: { id: 1 }, wayland: { appId: "google-chrome" } }
const ghostty = { title: "◑ deploy", address: "0xc3", workspace: { id: 2 }, wayland: { appId: "com.mitchellh.ghostty" } }
const dashed = { title: "Bug 123 - fix the parser", address: "0xc4", workspace: { id: 3 }, wayland: { appId: "code" } }

assert.equal(Model.label(firefox), "(2) WhatsApp", "the app name must be stripped from the title")
assert.equal(Model.detail(firefox), "Mozilla Firefox", "the stripped app name becomes the second row")
assert.equal(Model.label(chrome), "inbox", "a plain hyphen separator is handled too")
assert.equal(Model.detail(chrome), "Google Chrome")
assert.equal(Model.label(ghostty), "◑ deploy", "a title with no app suffix is left alone")
assert.equal(Model.detail(ghostty), "Ghostty", "a reverse-DNS app id is prettified for the second row")
assert.equal(Model.label(dashed), "Bug 123 - fix the parser",
  "a dash that is not the app name must not be stripped")
assert.equal(Model.detail(dashed), "Code")
assert.equal(Model.label({ address: "0xc5", workspace: { id: 1 } }), "Untitled", "a window with no title still labels")

console.log("all checks passed")

// --- workspace hint ---
// The workspace is only worth showing when picking the window would move you
// off the one you are on.
assert.equal(Model.workspaceHint(firefox, 2), "", "same workspace shows nothing")
assert.equal(Model.workspaceHint(firefox, 3), "→ 2", "a different workspace is called out")
assert.equal(Model.workspaceHint(dashed, 2), "→ 3")
assert.equal(Model.workspaceHint({}, 2), "", "a window with no workspace shows nothing")
assert.equal(Model.workspaceHint(firefox, -1), "→ 2", "unknown current workspace still reports")
console.log("workspace hint checks passed")

// --- windowAt: resolving a click to a window ---
// Hyprland reports no focus event when a window is clicked under an
// exclusive-keyboard layer, so the switcher consumes the click and resolves the
// target itself. Geometry comes from lastIpcObject.at / .size.
function win(id, x, y, w, h, ws, rank) {
  return { title: id, address: "0x" + id, workspace: { id: ws },
           lastIpcObject: { class: id, at: [x, y], size: [w, h], focusHistoryID: rank } }
}
const back  = win("back",  0,   0,   800, 600, 2, 3)
const front = win("front", 100, 100, 400, 300, 2, 0)   // overlaps back, focused later
const other = win("other", 0,   0,   800, 600, 5, 1)   // different workspace

assert.equal(Model.windowAt([back, front], 150, 150, 2).title, "front",
  "overlapping windows resolve to the most recently focused, i.e. the visible one")
assert.equal(Model.windowAt([back, front], 700, 550, 2).title, "back",
  "a point outside the top window falls through to the one below")
assert.equal(Model.windowAt([back, front], 900, 900, 2), null, "a point over no window is null")
assert.equal(Model.windowAt([other], 10, 10, 2), null, "windows on other workspaces are not clickable")
assert.equal(Model.windowAt([other], 10, 10, -1).title, "other", "unknown workspace does not filter")
assert.equal(Model.windowAt([{ title: "ghost" }], 10, 10, 2), null, "a non-window toplevel is never a target")
assert.equal(Model.windowAt([], 10, 10, 2), null)
assert.equal(Model.windowAt(null, 10, 10, 2), null)
console.log("windowAt checks passed")
