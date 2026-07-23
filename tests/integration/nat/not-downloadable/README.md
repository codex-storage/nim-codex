# NAT not-downloadable scenario

## Scenario

A node behind a NAT with no relay is `NotReachable` and announces no dialable
address. A remote peer can never dial it, so a download from it fails.

## Topology

```
node B ──── lan ──── router (NAT) ──── wan ──── bootstrap A
                                         └────── node C (reachable)
```

- **bootstrap A** — public node on the wan, autonat server, started with
  `--nat=extip`. Unlike not-reachable, it runs *without* `--relay-server`, so B
  has no relay to fall back to.
- **router** — `lan -> wan` masquerade and *no* inbound forward, so B can dial
  out but nothing can dial back in.
- **node B** — `nat=auto`, on the lan. It joins via A, AutoNAT finds it
  unreachable, and with no relay it ends up announcing nothing dialable.
- **node C** — `nat=auto`, directly on the wan, so AutoNAT finds it
  `Reachable`. It is the peer that tries (and fails) to download from B.

## Run

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/not-downloadable/testnotdownloadable.nim
```

Builds the shared image and brings the compose topology up and down. Rootless, but
needs the host netfilter modules — if the router fails on iptables:
`sudo modprobe iptable_nat nf_conntrack`.

## Expected result

B is `NotReachable` and announces no address, while C is `Reachable`. B uploads
a file, then C tries to fetch its manifest over the network and fails.

Per-run container logs (router, bootstrap, client, node) are written before teardown to
`tests/integration/logs/<timestamp>__NAT_not_downloadable/<test>/<service>.log`.
