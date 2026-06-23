# Google Connection Filtering Audit

Audit date: 2026-06-22 (Australia/Adelaide)

## Architecture and connection trace

1. macOS performs DNS outside this app. The app does not intercept DNS and does not retain queried hostnames or CNAME chains.
2. `ConnectionMonitorService.scan()` runs `lsof -i -n -P`; `-n` forces numeric IP endpoints.
3. `ConnectionParser` creates `NetworkConnection` values containing remote IP addresses only.
4. Google blocking downloads `goog.json` and `cloud.json`, stores their IPv4/IPv6 CIDRs as an enabled managed blocklist, and generates inbound/outbound PF `quick` block rules.
5. `FirewallBlockService.apply()` writes the rules to the app anchor and loads it using `pfctl`.
6. PF compares each packet's source/destination IP with the generated IP/CIDR rules. It has no hostname, wildcard, suffix, Unicode, punycode, or CNAME context.

## End-to-end result before the fix

The database contained an enabled 1,101-entry Google blocklist and the generated anchor contained matching rules. Every resolved address tested below was inside a generated Google CIDR. Nevertheless, direct HTTPS connections succeeded because the rules were loaded into `com.connectionmanager.blocked`, while the stock `/etc/pf.conf` only invokes `com.apple/*`. The orphan anchor was never evaluated.

| Domain tested | Expected | Actual before fix | Matching rule observed |
| --- | --- | --- | --- |
| google.com and subdomains | Block | Allowed | `142.250.0.0/15` or `192.178.0.0/15` |
| gstatic.com and subdomains | Block | Allowed | `192.178.0.0/15` |
| googleapis.com and subdomains | Block | Allowed | `192.178.0.0/15` |
| youtube.com and subdomains | Block | Allowed | `192.178.0.0/15` |
| ytimg.com and subdomains | Block | `i.ytimg.com` allowed; apex had no A/AAAA answer | `142.250.0.0/15` or `192.178.0.0/15` |
| doubleclick.net and subdomains | Block | Allowed | `192.178.0.0/15` |
| googletagmanager.com and subdomains | Block | Allowed | `192.178.0.0/15` |
| googleusercontent.com and subdomains | Block | Allowed | `142.250.0.0/15` or `192.178.0.0/15` |

Concrete HTTPS attempts to `google.com`, `mail.google.com`, `maps.google.com`, `fonts.googleapis.com`, `youtube.com`, `i.ytimg.com`, and `accounts.google.com` all connected and returned HTTP responses before the fix.

## Defects and limitations

- **Critical: orphan PF anchor.** `FirewallBlockService.anchorName` selected an anchor absent from `/etc/pf.conf`. Fixed by loading below the invoked `com.apple/*` hierarchy and migrating the legacy saved name.
- **Critical: startup protection used orphan anchors too.** `StartupProtectionService` could report rules loaded even though its anchors were unreachable. All startup/rules/blocklist anchor names now use the invoked hierarchy.
- **Allowlist precedence was exact-string only in rule generation.** An allowed host inside a blocked CIDR was not exempted. Fixed by generating allowlist `pass quick` rules before all block rules; `FirewallRuleEvaluator` also implements CIDR-aware allow-first decisions and exact evaluation reasons.
- **No domain filtering exists.** Case, whitespace, wildcard, suffix, punycode, Unicode normalization, DNS-cache refresh, and CNAME matching are not applicable because hostnames never enter the enforcement pipeline.
- **DNS is not filtered.** Cached and fresh DNS answers both lead to IP-only PF evaluation. DNS itself remains available.
- **Coverage follows published IP ownership, not domain ownership.** Google Cloud customer ranges are overblocked, while any named service served from an unpublished or third-party range can bypass the preset.
- **Rule refresh is manual.** The range cache refreshes only when the user enables or explicitly refreshes Google blocking.

## Code locations

- DNS omission/numeric capture: `ConnectionMonitorService.swift:14-27`
- Endpoint parsing: `ConnectionParser.swift:49-76`
- Google feed retrieval: `GoogleIPRangeService.swift:22-48`
- Managed range persistence: `FirewallDatabase.swift:199-249`
- Rule assembly and allowlist precedence: `FirewallDashboardViewModel.swift:485-503`, `FirewallRuleGenerator.swift:6-31`
- PF installation: `FirewallBlockService.swift:63-79`
- Startup PF installation: `StartupProtectionService.swift:28-78`
- Auditable evaluation reasons: `FirewallRuleEvaluator.swift`
- Regression coverage: `FirewallFilteringTests.swift`
