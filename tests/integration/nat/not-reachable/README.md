# NAT not-reachable scenario

## Scenario

A node behind a NAT that cannot be reached from outside must be detected
`NotReachable` and fall back to bootstrap A's relay.

## Topology

```
node B ──── lan ──── router (NAT) ──── wan ──── bootstrap A
```

- **bootstrap A** — public node on the wan, runs the relay + autonat server,
  started with `--nat=extip` so it advertises its own public address.
- **router** — two interfaces (lan + wan). Does `lan -> wan` masquerade and *no*
  inbound forward, so B can dial out but nothing can dial back in.
- **node B** — `nat=auto`, on the lan. Its default route points at the router,
  so all wan-bound traffic is NATed. It fetches A's SPR over A's API to join,
  then AutoNAT probes A and finds itself unreachable.

The wan uses a real public range because our address policy keeps only public
dialable addresses: a private observed address would be filtered out and AutoNAT
would stay `Unknown` instead of `NotReachable`. The wan is `internal` so that
range never leaks to host routes.

## Run

```bash
make testNatIntegration STORAGE_INTEGRATION_TEST_INCLUDES=not-reachable
```

Runs this scenario (omit the var to run every NAT scenario). Builds the shared
image and runs `testnotreachable.nim`, which brings the compose topology up and
down. Rootless, but needs the host netfilter modules — if the router fails on
iptables: `sudo modprobe iptable_nat nf_conntrack`.

## Expected result

B ends up `NotReachable` with the relay running, announcing only its circuit
(relay) address — never a direct one. Its `debug/info`:

```json
{
  "nat": {
    "reachability": "NotReachable",
    "clientMode": true,
    "relayRunning": true,
    "portMapping": "none"
  }
}
```

Per-run container logs (router, bootstrap, node) are written before teardown to
`tests/integration/logs/<timestamp>__NAT_not_reachable/<test>/<service>.log`.
