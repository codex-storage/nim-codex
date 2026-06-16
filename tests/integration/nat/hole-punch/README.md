# NAT hole-punch scenario

## Scenario

Two nodes are each behind their **own** NAT, so neither can reach the other on a
shared lan. Both are `NotReachable` and take a relay reservation on A. When D
downloads from B through the relay, B drives a **coordinated** DCUtR
simultaneous-open and starts hole-punching.

## Topology

```
node B ── lan1 ── router1 (NAT) ──┐
                                  ├── wan ── bootstrap A (relay + autonat)
node D ── lan2 ── router2 (NAT) ──┘
```

- **bootstrap A** — public node on the wan, autonat + relay server.
- **router1 / router2** — `lan -> wan` masquerade, *no* inbound forward.
- **node B** — behind router1, NotReachable, uploaded to and downloaded from.
  Holds the inbound relayed connection, so it is the DCUtR initiator.
- **node D** — behind router2, NotReachable, downloads from B through the relay.

## Run

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/hole-punch/testholepunch.nim
```

Rootless, but needs the host netfilter modules — if a router fails on iptables:
`sudo modprobe iptable_nat nf_conntrack`.

## Expected result

Both nodes are `NotReachable`. D downloads from B through the relay, opening a
relayed connection; B then runs DCUtR and the connection is upgraded to a direct
one. The test polls B's `/debug/info` and asserts its connection to D becomes
non-relayed (`connections[].direct == true` for D's peerId).

Per-run container logs are written before teardown to
`tests/integration/logs/<timestamp>__NAT_hole_punching/<test>/<service>.log`.
