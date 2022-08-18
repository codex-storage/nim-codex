import std/strutils, stew/byteutils, parseutils, hashes, tables, sequtils, sets
import libp2p
import libp2p/protocols/pubsub/rpc/messages
import libp2p/protocols/pubsub/peertable
import testground_sdk

proc msgIdProvider(m: Message): Result[MessageID, ValidationResult] =
  return ok(($m.data.hash).toBytes())

testground(client):
  let
    myId = await client.signalAndWait("setup", client.testInstanceCount)
    # Ugly IP generation
    myIp = client.testSubnet.split('.')[0..1].join(".") & ".1." & $myId
  await client.updateNetworkParameter(
    NetworkConf(
      network: "default",
      ipv4: some myIp & "/24",
      enable: true,
      callback_state: "network_setup",
      callback_target: some client.testInstanceCount,
      routing_policy: "accept_all",
      default: LinkShape(
        latency: 100000000,
      #  jitter: 100000000,
      )

    )
  )

  # Subscribing early to the pubsub topic to make sure we don't
  # miss any address
  let addressQueue = client.subscribe("addresses")

  # The sidecar will signal for "network_setup" when the network is ready
  # (callback_state above)
  await client.waitForBarrier("network_setup", client.testInstanceCount)

  let
    ma = MultiAddress.init("/ip4/" & myIp & "/tcp/0").tryGet()
    rng = libp2p.crypto.newRng()
    switch =
      SwitchBuilder.new()
      .withRng(rng)
      .withAddress(ma)
      .withNoise()
      .withMplex()
      .withTcpTransport()
      .withMaxConnections(client.testInstanceCount * 2)
      .build()

    pubsub = GossipSub.init(
      switch = switch,
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true, # Signing take a few milliseconds
      triggerSelf = true)
  switch.mount(pubsub)

  await switch.start()
  await pubsub.start()

  let gotMsg = newFuture[void]()

  pubsub.subscribe("letopic",
    proc (topic: string, data: seq[byte]) {.async.} =
      doAssert data[0] == 12
      gotMsg.complete()
  )

  # Ugly broadcast
  await client.publish("addresses", $myId & "," & $switch.peerInfo.addrs[0] & "," & $switch.peerInfo.peerId)
  var
    peersInfo: seq[string]
    toConnect = client.testInstanceCount
  # Retrieve every addresses
  while peersInfo.len < toConnect:
    peersInfo.add(await addressQueue.popLast())

  rng.shuffle(peersInfo)
  # Connect to 15 peers max (in local scenario I had issues when creating
  # too many connections (>2500), caused "No route to host" errors.)
  if peersInfo.len > 15:
    peersInfo = peersInfo[0..<15]
  for p in peersInfo:
    let dress = p.split(",")
    let pid = PeerId.init(dress[2]).tryGet()
    var otherId: int
    discard parseInt(dress[0], otherId)
    toConnect.dec
    if otherId < myId and pid != switch.peerInfo.peerId:
      try:
        await switch.connect(pid, @[MultiAddress.init(dress[1]).tryGet()])
        echo "Connected to ", dress, " from ", myId
      except CatchableError as exc:
        echo "CAN'T DIAL ", dress, " from ", myId
        echo exc.msg

  # safety sleep
  await sleepAsync(1.seconds)
  discard await client.signalAndWait("readyforaction", client.testInstanceCount)

  let start = Moment.now()
  if myId == 1:
    # First node publishes
    discard await pubsub.publish("letopic", @[12.byte])

  if await gotMsg.withTimeout(60.seconds):
    echo "FINISHED ",myId, ": ", Moment.now() - start
  else:
    echo myId, " never got the message :'("

  discard await client.signalAndWait("finished", client.testInstanceCount)

  await switch.stop()
