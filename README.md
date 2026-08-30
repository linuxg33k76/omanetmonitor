# OmaNetMonitor

Bar plugin that watches your machine's established outbound TCP connections
and flags any whose remote IP geolocates outside a country/region you allow.

## Installation

Requires [Omarchy](https://omarchy.org/). Install and enable the plugin, then
add it to the bar:

```bash
omarchy plugin add https://github.com/linuxg33k76/omanetmonitor.git --enable --yes
omarchy bar put omanetmonitor --section right
```

Plugins run as unsandboxed code inside `omarchy-shell` — review the source
before enabling anything, including this repo.

## Uninstall

```bash
omarchy plugin remove omanetmonitor --yes
```

This disables the plugin and deletes its git checkout from
`~/.config/omarchy/plugins/omanetmonitor/` (installed this way, it's
git-managed, so it's removed outright rather than backed up — the source
stays on GitHub if you want it again). It leaves behind
`~/.cache/omarchy/omanetmonitor/geoip-cache.json`; delete that too if you
want no trace left:

```bash
rm -rf ~/.cache/omarchy/omanetmonitor
```

## How it works

Every `refreshIntervalSec` seconds (default 30), `bin/omanetmonitor-scan`:

1. Reads established outbound connections from `ss -Htn state established`,
   dropping anything private/loopback/link-local (RFC1918, `127.0.0.0/8`,
   `169.254.0.0/16`, IPv6 equivalents, etc).
2. Looks up each remaining public IP's country, using a local cache at
   `~/.cache/omarchy/omanetmonitor/geoip-cache.json` (7-day TTL) so repeat
   IPs don't trigger repeat lookups. New IPs are resolved via an HTTPS GET
   to [ipwho.is](https://ipwho.is) — a free, no-API-key GeoIP service. This
   is the one place the plugin talks to a third party: it sends the IP
   addresses your machine is already talking to, not your own IP or any
   other data.
3. Flags every connection whose country code isn't in your allow-list, and
   prints all of them (sorted by connection count) as JSON.

The bar icon is a globe normally, and turns into an urgent-colored warning
glyph with a count badge when anything is flagged. Click it to see the
IP address, country, and port for every flagged connection in a scrollable
list, and to edit the allow-list or scan interval inline.

## Settings

- **Allowed** — comma-separated ISO 3166-1 alpha-2 country codes that are
  never flagged (e.g. `US` or `US,CA,MX` for a region). Default `US`.
- **Scan interval** — how often to rescan, in seconds (10–600). Default 30.

Both can also be set from the CLI:

```bash
omarchy bar set omanetmonitor allowedCountries "US,CA"
omarchy bar set omanetmonitor refreshIntervalSec 60 --json
```

## Exporting to CSV

The **Save to** field at the bottom of the panel holds a destination path,
pre-filled with `~/omanetmonitor-flagged-export-<timestamp>.csv` the first time you
open the panel — edit it to save wherever you want (an absolute path, a
`~/...` path, or a bare filename, which is resolved relative to your home
directory). Click **Export CSV** (or press Enter in the field) to write the
currently displayed flagged-connections list — IP address, country code,
country name, port, and connection count — to that file. There's no native
"Save As" file-browser dialog (the Omarchy shell avoids those inside its
layer-shell popups); typing the path is the mechanism for choosing where it
goes. A status line under the button confirms the write or reports why it
failed (e.g. a directory that doesn't exist).

## Limitations

- TCP only (UDP has no persistent "established" state to enumerate the same
  way).
- GeoIP lookups are best-effort and rate-limited (max 8 new lookups per
  scan) — a burst of brand-new destinations may take a couple of scan
  cycles to fully resolve. Unresolved IPs show as "Unknown" and are treated
  as flagged (fail closed) until resolved.
- Country-level geolocation from a free IP database is not perfectly
  accurate for every IP block (VPN exit nodes, cloud provider ranges, and
  anycast IPs in particular can resolve to a different country than the
  physical server).
- The scrollable list is capped at 500 flagged entries per scan as a safety
  bound, not a practical limit — a real host won't come close.
