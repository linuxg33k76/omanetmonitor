// Shared helpers for OmaNetMonitor: locating the plugin-local scan script and
// interpreting its JSON output.

// QUrl (as Qt.resolvedUrl hands to QML) or plain string -> local filesystem
// path. Only a leading "file://" is stripped; percent-escapes decode.
function localFilePath(value) {
  var text = String(value || "")
  if (text.indexOf("file://") === 0) text = text.substring(7)
  try {
    return decodeURIComponent(text)
  } catch (error) {
    return text
  }
}

// Normalizes a comma-separated country-code string: uppercase, trimmed,
// de-duplicated, empty entries dropped. Falls back to ["US"] when nothing
// usable is left.
function normalizeCountryList(raw) {
  var seen = {}
  var out = []
  var parts = String(raw || "").split(",")
  for (var i = 0; i < parts.length; i++) {
    var code = parts[i].trim().toUpperCase()
    if (code === "" || seen[code]) continue
    seen[code] = true
    out.push(code)
  }
  return out.length > 0 ? out : ["US"]
}

// Parses the scan script's stdout. Returns null on anything unparsable so
// callers can distinguish "bad output" from "clean scan, nothing flagged".
function parseScanOutput(text) {
  var trimmed = String(text || "").trim()
  if (trimmed === "") return null
  try {
    var data = JSON.parse(trimmed)
    if (!data || typeof data !== "object" || !Array.isArray(data.flagged)) return null
    return data
  } catch (error) {
    return null
  }
}

function formatRelativeTime(epochSeconds) {
  if (!epochSeconds) return "never"
  var deltaSec = Math.max(0, Math.round(Date.now() / 1000 - epochSeconds))
  if (deltaSec < 5) return "just now"
  if (deltaSec < 60) return deltaSec + "s ago"
  var deltaMin = Math.round(deltaSec / 60)
  if (deltaMin < 60) return deltaMin + "m ago"
  var deltaHour = Math.round(deltaMin / 60)
  return deltaHour + "h ago"
}

// CSV field quoting per RFC 4180: wrap in quotes and double any embedded
// quotes whenever the value contains a comma, quote, or newline (country
// names routinely contain commas, e.g. "Korea, Republic of").
function csvEscape(value) {
  var s = value === undefined || value === null ? "" : String(value)
  if (/[",\n\r]/.test(s)) return '"' + s.replace(/"/g, '""') + '"'
  return s
}

// Builds CSV text (header + one row per entry) for the flagged-connections
// list, in the same order the panel displays it.
function buildFlaggedCsv(entries) {
  var lines = ["IP Address,Country Code,Country Name,Port,Connections"]
  var list = Array.isArray(entries) ? entries : []
  for (var i = 0; i < list.length; i++) {
    var e = list[i]
    lines.push([
      csvEscape(e.ip),
      csvEscape(e.countryCode),
      csvEscape(e.countryName),
      csvEscape(e.port),
      csvEscape(e.count)
    ].join(","))
  }
  return lines.join("\n") + "\n"
}

// "omanetmonitor-flagged-export-20260830-143022.csv" — date/time appended
// to the base name right before the extension, so it sorts and reads
// naturally and never collides with a previous export in the same second.
function defaultExportFilename() {
  var d = new Date()
  function pad(n) { return n < 10 ? "0" + n : String(n) }
  var stamp = d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate())
    + "-" + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds())
  return "omanetmonitor-flagged-export-" + stamp + ".csv"
}
