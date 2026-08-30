# OmaNetMonitor

Bar plugin that watches your machine's established outbound TCP connections
and flags any whose remote IP geolocates outside a country/region you allow.

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
   prints the top 10 (by connection count) as JSON.

The bar icon is a globe normally, and turns into an urgent-colored warning
glyph with a count badge when anything is flagged. Click it to see the
IP address, country, and port for each flagged connection, and to edit the
allow-list or scan interval inline.

## Settings

- **Allowed** — comma-separated ISO 3166-1 alpha-2 country codes that are
  never flagged (e.g. `US` or `US,CA,MX` for a region). Default `US`.
- **Scan interval** — how often to rescan, in seconds (10–600). Default 30.

Both can also be set from the CLI:

```bash
omarchy bar set omanetmonitor allowedCountries "US,CA"
omarchy bar set omanetmonitor refreshIntervalSec 60 --json
```

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
