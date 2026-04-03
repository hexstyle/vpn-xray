# OpenWrt `shadowsocks-libev` Consumer

This profile is not the main installation target of this repository.

It exists for routers that already use `shadowsocks-libev` and need to consume the same shared destination list as the GL router.

Current support level:

- shared-rules sync
- domain-to-IPv4 snapshot expansion
- `dst_ips_forward` updates for `shadowsocks-libev`

Use it only if you explicitly need that secondary consumer.
