# NAT upnp scenario

## Scenario

A node behind a NAT becomes `Reachable` by mapping its port over UPnP — the
router forwards nothing on its own, the node asks for the mapping and no relay is
needed.

## Topology

```
node B ──── lan ──── router (NAT + miniupnpd) ──── wan ──── bootstrap A
```

- **bootstrap A** — public node on the wan, runs the relay + autonat server.
- **router** — `lan -> wan` masquerade and *no* static forward. It runs
  `miniupnpd` (real nftables backend) as the UPnP gateway, with PCP/NAT-PMP
  disabled so libplum falls back to UPnP.
- **node B** — `nat=auto`, on the lan. First detected `NotReachable`, it maps its
  TCP listen (8070) and UDP disc (8090) ports over UPnP; the resulting DNAT lets
  A's dial-back reach it, so the next AutoNAT round flips it to `Reachable`.

The wan public range and `internal` flag work as in
[not-reachable](../not-reachable/README.md); the public wan IP also keeps
miniupnpd from treating the setup as double-NAT and refusing to forward.

## Run

Every NAT scenario:

```bash
make testNatIntegration
```

Just this one — same `STORAGE_INTEGRATION_TEST_INCLUDES` filter as testIntegration,
with the test file path:

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/upnp/testupnp.nim
```

Builds the shared image and brings the compose topology up and down. Rootless, but
needs the host netfilter modules — if the router fails on iptables:
`sudo modprobe iptable_nat nf_conntrack`.

## Expected result

B ends up `Reachable`, the relay not running, announcing its direct address with
an active UPnP mapping. Its `debug/info`:

```json
{
  "nat": {
    "reachability": "Reachable",
    "clientMode": false,
    "relayRunning": false,
    "portMapping": "upnp"
  }
}
```

Per-run container logs (router, bootstrap, node) are written before teardown to
`tests/integration/logs/<timestamp>__NAT_upnp/<test>/<service>.log`.
