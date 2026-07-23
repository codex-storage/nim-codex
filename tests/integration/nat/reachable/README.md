# NAT reachable scenario

## Scenario

A node behind a NAT whose port is forwarded must be detected `Reachable` and
keep its direct address — no relay fallback.

## Topology

```
node B ──── lan ──── router (NAT + port forward) ──── wan ──── bootstrap A
```

- **bootstrap A** — public node on the wan, runs the relay + autonat server.
- **router** — `lan -> wan` masquerade *plus* a static DNAT forwarding B's TCP
  listen port (8070) and UDP disc port (8090) inbound. No miniupnpd: the router
  opens the port itself, so B maps nothing.
- **node B** — `nat=auto`, on the lan, default route through the router. It dials
  out from its listen port (8070) and the masquerade keeps that port, so A
  observes it at `7.7.7.2:8070` — exactly what the DNAT forwards back, so the
  dial-back reaches it.

The wan public range and `internal` flag work as in
[not-reachable](../not-reachable/README.md).

## Run

Every NAT scenario:

```bash
make testNatIntegration
```

Just this one — same `STORAGE_INTEGRATION_TEST_INCLUDES` filter as testIntegration,
with the test file path:

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/reachable/testreachable.nim
```

Builds the shared image and brings the compose topology up and down. Rootless, but
needs the host netfilter modules — if the router fails on iptables:
`sudo modprobe iptable_nat nf_conntrack`.

## Expected result

B ends up `Reachable`, the relay not running, announcing its direct address —
not a circuit one. Its `debug/info`:

```json
{
  "nat": {
    "reachability": "Reachable",
    "clientMode": false,
    "relayRunning": false,
    "portMapping": "none"
  }
}
```

Per-run container logs (router, bootstrap, node) are written before teardown to
`tests/integration/logs/<timestamp>__NAT_reachable/<test>/<service>.log`.
