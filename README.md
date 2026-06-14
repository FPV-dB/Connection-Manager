# Firewall Dashboard

Firewall Dashboard is a private local macOS SwiftUI utility for defensive network visibility and PF firewall management.

It combines:

- TCPView-style live TCP/UDP connection monitoring.
- Manual PF block/unblock controls.
- Imported IP/CIDR blocklists.
- Opt-in Geo/IP country-level CIDR blocklists.
- Explicit selected-connection GeoIP/reputation lookups using the user's browser.
- Trusted allowlist entries.
- A pfSense-inspired dashboard with native macOS layout and menu bar access.
- SQLite persistence for firewall state and event logs.

## App Structure

The main window is `Firewall Dashboard` and includes:

- Dashboard
- Live Connections
- Blocked IPs
- Blocklists
- Country Blocking
- Rules
- Logs
- Settings

Closing the window hides it instead of quitting. The app remains available from the menu bar extra named `Connections`.

## Data Collection

Live connections are collected with macOS command-line tools through `Process` on background tasks:

- Primary: `/usr/sbin/lsof -i -n -P`
- Fallback: `/usr/sbin/netstat -anv`

Connections are deduplicated by protocol, local address, local port, remote address, remote port, and PID. First seen and last seen timestamps are tracked in memory only. Live connections are not persisted by default.

## GeoIP and Reputation Lookup

Live connection lookups are explicit user actions only. The app never performs automatic bulk lookups and never runs traceroute.

When a public remote IP is selected, the user can open a third-party lookup page in the default browser. Provider presets include:

- ipinfo.io
- Hurricane Electric BGP
- AbuseIPDB
- IP Location
- IP2Location Demo
- DomainTools WHOIS
- Cisco Talos
- VirusTotal

The app substitutes the selected IP into the provider URL template and opens it with `NSWorkspace`. It does not scrape these pages, embed them, or require API keys.

Before first use, the app warns that the selected IP address will be sent to a third-party website. Local, private, multicast, broadcast, and unspecified addresses are refused for lookup.

GeoIP and reputation results are approximate and can be wrong because of VPNs, CDNs, proxies, cloud hosting, and mobile networks.

## Advanced Network Tools

Traceroute and ping are optional advanced actions on the selected connection only. They are never used by default, never run automatically, and never run in bulk.

Traceroute uses `/usr/sbin/traceroute` for IPv4 and `/usr/sbin/traceroute6` or `traceroute -6` for IPv6 where available. Ping uses `/sbin/ping`.

Before first traceroute use, the app warns that traceroute sends network probes toward the selected host and may be logged, blocked, or misleading. Output streams live into the details panel and can be stopped, copied, or saved.

Local, private, multicast, broadcast, unspecified, and empty remote IPs are disabled for traceroute and ping.

## Persistence

The app stores firewall state in SQLite under Application Support:

```text
~/Library/Application Support/Live Connections Monitor/firewall.sqlite
```

Persisted data includes:

- Blocklists
- Blocklist entries
- Manual blocked IPs
- Trusted allowlist entries
- Firewall event logs
- Settings

## Blocklist Import

Supported import files:

- `.txt`
- `.ip`
- `.list`
- simple `.csv`

Rules:

- Blank lines are ignored.
- Lines beginning with `#` or `;` are ignored.
- CSV uses the first column.
- IPv4, IPv4 CIDR, IPv6, and IPv6 CIDR are accepted where practical.
- Invalid lines are skipped and counted.
- Duplicate entries are removed.
- Private LAN ranges are imported with warnings.

## Country Blocking

Country Blocking is opt-in only. No country rules are enabled by default.

Users can manually import country-level CIDR files from sources they provide, such as:

- IPdeny country zone files
- DB-IP country range exports
- MaxMind GeoLite2-derived exports if the user supplies their own licensed data
- Custom CSV country/IP/CIDR files

The app does not bundle proprietary GeoIP databases and does not scrape sources.

Country imports support IPv4 CIDR ranges and IPv6 CIDR ranges where practical. Imported countries can be enabled or disabled independently, assigned inbound/outbound/both direction, annotated with notes, previewed as generated PF rules, and simulated against active connections before applying.

Before applying country blocks, review the simulation panel. Country-level blocking is broad and may break websites, CDNs, APIs, game servers, software updates, cloud services, VPN endpoints, and legitimate users.

Allowlist entries are applied as overrides before rule generation. Private LAN, localhost, multicast, broadcast, and unspecified ranges are refused or warned by validation.

## PF Firewall Rules

Blocking uses macOS PF through a dedicated app-managed anchor:

```text
com.radioecology.blocked
```

Default anchor file:

```text
/etc/pf.anchors/com.radioecology.blocked
```

Generated rules use PF blocks only:

```pf
block drop in quick from <IP_OR_CIDR>
block drop out quick to <IP_OR_CIDR>
```

The app does not redirect traffic to `127.0.0.1`.

The app never flushes the global PF ruleset and never edits unrelated system firewall rules. The Rules page shows a read-only preview before applying.

## Admin Permission

Applying rules requires administrator permission. The current implementation uses `osascript` with administrator privileges to write the anchor file and reload only the app anchor:

```sh
pfctl -a com.radioecology.blocked -f /etc/pf.anchors/com.radioecology.blocked
pfctl -e
```

A production-grade privileged helper could replace this later, but the privileged boundary is isolated in `FirewallBlockService`.

## Safety Limits

Before import or blocking, validation refuses:

- `127.0.0.0/8`
- `::1`
- `0.0.0.0`
- `::`
- `224.0.0.0/4`
- `ff00::/8`
- `255.255.255.255`

Private LAN ranges warn before import:

- `10.0.0.0/8`
- `172.16.0.0/12`
- `192.168.0.0/16`
- `fc00::/7`

Default gateway detection is included in the lower-level firewall service for manual block confirmation paths.

## Not Included

This app does not implement packet capture, MITM, spoofing, credential capture, deauthentication, scanning, exploitation, stealth behavior, or traffic redirection.
