# NAT connection-reversal scenario

## Scenario

A node behind a NAT is reachable only through A's relay. When the reachable node
C dials it through the relay, the relayed node dials C back directly (C is
public) and the relayed connection is upgraded to a direct one.

This is a unilateral reversal — only the NATed node dials, because C is public.
It is not a coordinated hole punch; see `../hole-punch` for the both-NATed case.

## Topology

```
node B ──── lan ──── router (NAT) ──── wan ──── bootstrap A (relay)
                                        └────── node C (reachable)
```

- **bootstrap A** — public node on the wan, autonat + relay server.
- **router** — `lan -> wan` masquerade and *no* inbound forward.
- **node B** — `nat=auto`, on the lan. NotReachable, takes a relay reservation
  on A. When C reaches it through the relay, its hole-punching handler dials C
  back directly and closes the relayed connection.
- **node C** — `nat=auto`, directly on the wan, so it is `Reachable`. It dials B
  through the relay.

## Run

```bash
make testNatIntegration \
  STORAGE_INTEGRATION_TEST_INCLUDES=tests/integration/nat/connection-reversal/testconnectionreversal.nim
```

Builds the shared image and brings the compose topology up and down. Rootless, but
needs the host netfilter modules — if the router fails on iptables:
`sudo modprobe iptable_nat nf_conntrack`.

## Expected result

B is `NotReachable` behind the relay, C is `Reachable`. C downloads from B
through the relay, which opens a relayed connection; B then dials C back
directly. The direct upgrade has no REST surface, so the test asserts on B's log
line `Direct connection created.`.

Per-run container logs (router, bootstrap, client, node) are written before teardown to
`tests/integration/logs/<timestamp>__NAT_connection_reversal/<test>/<service>.log`.
