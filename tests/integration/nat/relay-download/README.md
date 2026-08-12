# NAT relay-download scenario

## Scenario

A node behind a NAT falls back to bootstrap A's relay and announces its circuit
address. A reachable node C finds it as a provider and downloads its data
through the relay.

## Topology

```
node B ──── lan ──── router (NAT) ──── wan ──── bootstrap A (relay)
                                        └────── node C (reachable)
```

- **bootstrap A** — public node on the wan, autonat + relay server, started with
  `--nat=extip`.
- **router** — `lan -> wan` masquerade and *no* inbound forward, so B can dial
  out but nothing can dial back in.
- **node B** — `nat=auto`, on the lan. AutoNAT finds it unreachable, so it takes
  a relay reservation on A and announces its circuit address.
- **node C** — `nat=auto`, directly on the wan, so AutoNAT finds it
  `Reachable`. It is the peer that downloads from B through the relay.

## Run

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/relay-download/testrelaydownload.nim
```

Builds the shared image and brings the compose topology up and down. Rootless, but
needs the host netfilter modules — if the router fails on iptables:
`sudo modprobe iptable_nat nf_conntrack`.

## Expected result

B is `NotReachable` and announces its circuit address, while C is `Reachable`.
B uploads a file, then C fetches it over the network through the relay and gets
the same content back.

A second check ensures that the relay server does not expose private addresses.

Per-run container logs (router, bootstrap, client, node) are written before teardown to
`tests/integration/logs/<timestamp>__NAT_relay_download/<test>/<service>.log`.
