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

var COUNTRY_CODE_RE = /^[A-Z]{2}$/
var MAX_ALLOWED_CODES = 50
var MAX_ALLOWED_RAW_LEN = 2000

// Normalizes a comma-separated country-code string: uppercase, trimmed,
// de-duplicated, and validated as exactly two letters (ISO 3166-1
// alpha-2) — a malformed entry is dropped rather than passed through, since
// this string is later handed to the scan script via argv. Bounded on both
// input length and output cardinality. Falls back to ["US"] when nothing
// usable is left.
function normalizeCountryList(raw) {
  var seen = {}
  var out = []
  var parts = String(raw || "").substring(0, MAX_ALLOWED_RAW_LEN).split(",")
  for (var i = 0; i < parts.length && out.length < MAX_ALLOWED_CODES; i++) {
    var code = parts[i].trim().toUpperCase()
    if (!COUNTRY_CODE_RE.test(code) || seen[code]) continue
    seen[code] = true
    out.push(code)
  }
  return out.length > 0 ? out : ["US"]
}

var MAX_SCAN_OUTPUT_LEN = 256 * 1024
var MAX_FLAGGED_ENTRIES = 500
var MAX_IP_LEN = 45 // longest possible IPv6 literal
var MAX_COUNTRY_NAME_LEN = 100
var MAX_COUNT = 1000000

// Clamps to a finite non-negative integer, optionally capped at `max`.
function sanitizeNonNegativeInt(value, max) {
  var n = Math.floor(Number(value))
  if (!isFinite(n) || n < 0) n = 0
  return max !== undefined ? Math.min(n, max) : n
}

// Re-validates one flagged-connection entry: the scan script already
// bounds/types these, but the panel treats its stdout as untrusted input
// crossing a process boundary and re-checks independently rather than
// trusting the producer. Returns null for anything malformed.
function sanitizeFlaggedEntry(e) {
  if (!e || typeof e !== "object") return null
  var ip = String(e.ip !== undefined && e.ip !== null ? e.ip : "")
  if (ip.length === 0 || ip.length > MAX_IP_LEN) return null
  var port = sanitizeNonNegativeInt(e.port, 65535)
  if (port < 1 || port > 65535) return null
  var code = String(e.countryCode !== undefined && e.countryCode !== null ? e.countryCode : "").toUpperCase()
  if (code !== "" && !COUNTRY_CODE_RE.test(code)) code = ""
  var name = String(e.countryName !== undefined && e.countryName !== null ? e.countryName : "").substring(0, MAX_COUNTRY_NAME_LEN)
  return {
    ip: ip,
    port: port,
    countryCode: code,
    countryName: name,
    count: sanitizeNonNegativeInt(e.count, MAX_COUNT),
    flagged: e.flagged === true
  }
}

// Parses the scan script's stdout. Returns null on anything unparsable so
// callers can distinguish "bad output" from "clean scan, nothing flagged".
// Every field is bounded/typed here rather than trusted as-is, and the
// flagged list is capped independently of whatever totalFlagged claims.
function parseScanOutput(text) {
  var trimmed = String(text || "").trim()
  if (trimmed === "" || trimmed.length > MAX_SCAN_OUTPUT_LEN) return null
  var data
  try {
    data = JSON.parse(trimmed)
  } catch (error) {
    return null
  }
  if (!data || typeof data !== "object" || !Array.isArray(data.flagged)) return null

  var flagged = []
  for (var i = 0; i < data.flagged.length && flagged.length < MAX_FLAGGED_ENTRIES; i++) {
    var entry = sanitizeFlaggedEntry(data.flagged[i])
    if (entry) flagged.push(entry)
  }

  return {
    generatedAt: sanitizeNonNegativeInt(data.generatedAt),
    totalConnections: sanitizeNonNegativeInt(data.totalConnections, MAX_COUNT),
    totalUniquePeers: sanitizeNonNegativeInt(data.totalUniquePeers, MAX_COUNT),
    totalFlagged: flagged.length,
    flagged: flagged
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

function timestampSuffix() {
  var d = new Date()
  function pad(n) { return n < 10 ? "0" + n : String(n) }
  return d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate())
    + "-" + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds())
}

// Inserts "-<current timestamp>" right before the extension (or appends it,
// if the path has none) — e.g. "~/x.csv" -> "~/x-20260830-143022.csv".
// Computed fresh on every call, so the stamp reflects when the file is
// actually written rather than whenever the default path was suggested.
function withExportTimestamp(path) {
  var p = String(path || "")
  var stamp = timestampSuffix()
  var dot = p.lastIndexOf(".")
  var slash = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
  if (dot > slash) return p.substring(0, dot) + "-" + stamp + p.substring(dot)
  return p + "-" + stamp
}
