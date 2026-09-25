.pragma library

// Pure logic behind the bar widget: the lighting state written by rgb.sh in
// ~/.local/state/azeroht-no-rgb.json, and the components listed by
// `rgb.sh components`. The widget only reads them: every change goes through
// the script.
var DEFAULTS = { enabled: false, off: [] }

// OpenRGB type -> label shown, when the type alone does not speak for itself.
var TYPE_LABELS = { DRAM: "RAM", LEDStrip: "LED strip" }

function parse(text) {
  try {
    return JSON.parse(text) || {}
  } catch (error) {
    console.warn("azeroht.no-rgb: unreadable JSON", error)
    return {}
  }
}

function isString(value) {
  return typeof value === "string"
}

// Safe state, whatever was read from the disk.
function normalize(raw) {
  var source = raw || {}
  return {
    enabled: source.enabled === true,
    off: Array.isArray(source.off) ? source.off.filter(isString) : []
  }
}

function describe(state) {
  return state.enabled ? "on" : "off"
}

function isComponentEnabled(state, name) {
  return state.off.indexOf(name) < 0
}

function toComponent(entry) {
  var type = isString(entry.type) ? entry.type : ""
  return { name: entry.name, label: TYPE_LABELS[type] || type || entry.name, isMissing: false }
}

function hasName(entry) {
  return entry !== null && typeof entry === "object" && isString(entry.name) && entry.name !== ""
}

// Components from `rgb.sh components`: OpenRGB name and readable label.
function parseComponents(text) {
  var list = parse(text)
  return Array.isArray(list) ? list.filter(hasName).map(toComponent) : []
}

function toName(component) {
  return component.name
}

// Detected components, followed by the excluded ones OpenRGB no longer sees
// (unplugged, renamed): they stay listed so they can be included again.
function withMissing(components, state) {
  var names = components.map(toName)
  var missing = []
  for (var index = 0; index < state.off.length; index++) {
    var name = state.off[index]
    if (names.indexOf(name) < 0) missing.push({ name: name, label: name, isMissing: true })
  }
  return components.concat(missing)
}

// rgb.sh command line, as an argument list: never a shell string.
function command(scriptPath, action, name, value) {
  if (name === undefined) return [scriptPath, action]
  return [scriptPath, action, String(name), String(value)]
}
