## Router Verification

When changing router logic, UI, sync flow, proxy flow, firewalling, or runtime control paths, always verify internet reachability and the end-to-end routing scheme after the change.

Required verification matrix on a real router when available:
- `VPN off`: hardware/path off, clients behind the router still have direct internet access.
- `VPN on + full`: transparent path on, full-mode routing works, internet access remains usable.
- `VPN on + selective`: transparent path on, selective-mode routing works, internet access remains usable for both selected and non-selected destinations.

Verification rules:
- Management-plane reachability is part of router verification: confirm SSH or HTTPS to the router still works after reloads or topology-affecting changes.
- Wi-Fi client reconnect after reboot or radio reload is part of management-plane verification when wireless settings, boot flow, or uplink failover could affect AP stability.
- For `WAN unplug -> Wi-Fi-only` scenarios, verify that a client can reconnect to the saved SSID/BSSID without manual password re-entry after cable removal, radio reload, and reboot.
- Prefer testing from the LAN client path behind the router, not only from router-local `curl`.
- Treat router-local proxy smoke as necessary but not sufficient.
- Check both control-plane status and data-plane behavior.
- When verifying reboot recovery, record when Wi-Fi or HTTP management comes back and when `path_state=active` comes back; eventual recovery alone is not sufficient.
- If the router is reachable after reboot but `xray_running=true` and `redsocks_running=true` while `transproxy_rule=false`, treat that as a boot regression and keep investigating.
- If you cannot test one of the three states on real traffic, say so explicitly in the final report.
- If a change risks breaking connectivity, inspect firewall/NAT counters and active runtime processes after the change.
- If Ethernet unplug / Wi-Fi uplink / Wi-Fi client access could be affected, explicitly verify that the router stays reachable over Wi-Fi with Ethernet absent, or say that you could not test it.

Network topology guardrails:
- Treat LAN bridge, Wi-Fi, WAN, and firewall zone topology as critical management-plane state.
- Do not change `network.lan.device`, `network.lan.ifname`, `network.@device[*].ports`, Wi-Fi AP/uplink bindings, or zone attachments by default.
- Do not enable or re-enable `wireless.*.random_bssid` on management AP radios unless the task explicitly requires unstable AP identities and the user accepts the reconnect risk.
- Preserve the existing router management path unless the task explicitly requires a topology change.
- If a topology change is necessary, add a rollback path or post-reload reachability check and verify both wired and Wi-Fi client access when available.

Boot and restore guardrails:
- Do not disable `codex-xray` or `codex-transproxy` init services as a workaround for boot ordering. If the hardware switch is on and config is ready, the path must restore during boot without waiting for watchdog polling as the primary recovery path.
- In `selective` mode, boot restoration must not block on a full DNS/rules refresh before returning the transproxy dataplane. Prefer restoring from the last resolved snapshot first, then refreshing in the background.

Git/push checks:
- If Git SSH auth is involved, verify the exact key the router uses.
- Prefer confirming both `ssh -T` auth and the actual Git transport/path the feature uses.
