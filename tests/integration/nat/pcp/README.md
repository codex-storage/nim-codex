# NAT pcp scenario

## Scenario

A node behind a NAT becomes `Reachable` by mapping its port over PCP — the router
forwards nothing on its own, the node asks for the mapping and no relay is needed.

## Topology

```
node B ──── lan ──── router (NAT + miniupnpd/PCP) ──── wan ──── bootstrap A
```

- **bootstrap A** — public node on the wan, runs the relay + autonat server.
- **router** — `lan -> wan` masquerade and *no* static forward. It runs
  `miniupnpd` (real nftables backend) with PCP/NAT-PMP enabled. libplum tries PCP
  first, so the mapping request goes over PCP and installs a real DNAT into the
  nft chains the entrypoint pre-creates.
- **node B** — `nat=auto`, on the lan. First detected `NotReachable`, it maps its
  TCP listen (8070) and UDP disc (8090) ports over PCP; the resulting DNAT lets
  A's dial-back reach it, so the next AutoNAT round flips it to `Reachable`.

The wan public range and `internal` flag work as in
[not-reachable](../not-reachable/README.md); the public wan IP also keeps
miniupnpd from refusing PCP/NAT-PMP as double-NAT.

## Run

Every NAT scenario:

```bash
make testNatIntegration
```

Just this one — same `STORAGE_INTEGRATION_TEST_INCLUDES` filter as testIntegration,
with the test file path:

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/pcp/testpcp.nim
```

Builds the shared image and brings the compose topology up and down. Rootless, but
needs the host netfilter modules — if the router fails on iptables:
`sudo modprobe iptable_nat nf_conntrack`.

## Expected result

B ends up `Reachable`, the relay not running, announcing its direct address with
an active PCP mapping. Its `debug/info`:

```json
{
  "nat": {
    "reachability": "Reachable",
    "clientMode": false,
    "relayRunning": false,
    "portMapping": "pcp"
  }
}
```

Per-run container logs (router, bootstrap, node) are written before teardown to
`tests/integration/logs/<timestamp>__NAT_pcp/<test>/<service>.log`.
