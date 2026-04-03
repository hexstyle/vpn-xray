# Shared Rules

This document covers the optional GitHub-backed destination list used by supported router profiles.

## Goal

Keep one operator-facing list of domains, IPv4 addresses, and IPv4 CIDRs in GitHub, then let each router translate that list into the consumer-specific form it actually needs.

## Canonical Layout

The shared-rules repo is operator-owned and external to this repo.

Expected shape:

- one GitHub repo chosen by the operator
- canonical file:
  - `lists/shared-targets.txt`

The repo is authoritative for the shared list content.

## Allowed Rule Types

One non-comment rule per line:

- domain
- IPv4 address
- IPv4 CIDR

Comments start with `#`.

## Router-Side Tool

Main script:

- `routers/common/files/router-rules`

Responsibilities:

- clone / fetch the shared repo on the router
- merge router-local edits against GitHub
- split domains vs literal IPv4/CIDR rules
- resolve domains to IPv4 where a consumer needs a snapshot
- maintain a local domain-to-IP mapping
- apply targets to the current consumer

Generated files on routers:

- repo checkout:
  - `/etc/router-rules/repo`
- domain-only list:
  - `/etc/router-rules/generated/domains.txt`
- literal IPv4/CIDR list:
  - `/etc/router-rules/generated/literals_ipv4.txt`
- resolved IPv4 snapshot:
  - `/etc/router-rules/generated/resolved_ipv4.txt`
- domain/IP mapping:
  - `/etc/router-rules/generated/resolution_map.tsv`
- GL dnsmasq ipset include:
  - `/tmp/dnsmasq.d/router-rules-xray-ipset.conf`

## Merge Policy

Two paths exist.

### Normal save when GitHub did not change

- keep the operator's exact local text
- commit and push that exact result
- do not invent merge annotations

### Conflict path when GitHub changed meanwhile

- fetch GitHub
- reset the local checkout to the GitHub version
- append only unique non-comment local lines that are not already present upstream
- commit the merged result on top of the GitHub version

This means:

- GitHub wins on conflicting existing lines
- truly unique local lines survive
- conflict-handling noise appears only when the remote really changed

## Git Transport

Recommended transport:

- fetch:
  - HTTPS
- push:
  - `ssh.github.com:443`

Why `443`:

- ordinary SSH/22 is not always reliable from embedded routers
- `ssh.github.com:443` proved more robust in this environment

## Resolver Strategy

Resolver order is layered so the routers survive different firmware quirks.

Preferred order:

1. DoH over HTTPS
2. configured DNS resolvers
3. nameservers discovered from router resolver files
4. `resolveip`

Important:

- the operator-facing file stays unchanged
- the domain-to-IP expansion is local and consumer-specific
- only IPv4 is currently considered for this rules layer

## Consumers

### GL child router

Consumer:

- `xray`

Behavior:

- `full` mode:
  - redirect all LAN TCP through the VPS path
- `selective` mode:
  - literal IPv4/CIDR rules go directly into `xray_selective_dst`
  - domain rules are written to a `dnsmasq --ipset` include
  - client DNS through the router populates `xray_selective_dst` dynamically

Important:

- GL selective mode is no longer a snapshot-only model for domains
- if a domain's IPv4 changes over time, the live set updates when clients resolve it through router DNS

### Secondary OpenWrt `shadowsocks-libev` router

Consumer:

- `shadowsocks-libev`

Behavior:

- sync repo
- resolve domains locally
- rebuild `dst_ips_forward`
- restart the relevant consumer/runtime

This is intentionally snapshot-based because that consumer does not match domains directly.

## Background Sync

Init service:

- `routers/common/files/router-rules-sync.init`

Behavior:

- runs every `RULES_SYNC_INTERVAL` seconds
- checks GitHub
- avoids redundant runtime work when the repo and applied ruleset already match
- updates status even on no-op checks
- triggers reset/cutover automatically when real drift is found

## UI Integration

GL web UI includes a `Selective Address Filter` block backed by:

- `/cgi-bin/xray-rules`

The block lets the operator:

- see the local routing mode
- edit the shared rules text
- sync changes with GitHub
- see whether the current router runtime is already aligned with the checked ruleset
- see the latest phase:
  - checking
  - drift detected
  - cutover in progress
  - verified
  - error

Mode semantics:

- `Routing Mode On This Router`
  - local-only
  - not pushed to GitHub
  - applies immediately on the current router
- `Sync GitHub Rules`
  - sync shared list content with GitHub
  - apply the relevant consumer update
  - perform reset/cutover automatically when needed

## Verification

Useful checks on GL:

```sh
ssh "$ROUTER_SSH" '/usr/bin/router-rules status-json'
ssh "$ROUTER_SSH" 'ipset list xray_selective_dst | sed -n "1,25p"'
ssh "$ROUTER_SSH" 'sed -n "1,20p" /tmp/dnsmasq.d/router-rules-xray-ipset.conf'
ssh "$ROUTER_SSH" 'iptables -t nat -S CODEX_TRANSPROXY'
```

Useful checks on the secondary `shadowsocks-libev` consumer:

```sh
ssh "$SECONDARY_ROUTER_SSH" '/usr/bin/router-rules status-json'
ssh "$SECONDARY_ROUTER_SSH" 'sed -n "1,40p" /etc/router-rules/generated/resolution_map.tsv'
ssh "$SECONDARY_ROUTER_SSH" 'uci -q show shadowsocks-libev.ss_rules | sed -n "1,12p"'
```

Useful check for the canonical repo:

```sh
git ls-remote "$RULES_REPO_FETCH_URL" HEAD
```
