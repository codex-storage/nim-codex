import pkg/chronos
import pkg/libp2p/peerinfo
import pkg/libp2p/multiaddress
import ./dagger/p2p/switch
import ./dagger/repo
import ./dagger/chunking
import ./dagger/bitswap

export peerinfo
export multiaddress

type
  Dagger* = ref object
    repo: Repo
    switch: Switch
    bitswap: Bitswap

proc info*(dagger: Dagger): PeerInfo =
  dagger.switch.peerInfo

proc start*(_: type Dagger,
            addresses: seq[MultiAddress]): Future[Dagger] {.async.} =
  let repo = Repo()
  let switch = Switch.create()
  let bitswap = Bitswap.start(switch, repo)
  switch.peerInfo.addrs.add(addresses)
  discard await switch.start()
  result = Dagger(repo: repo, switch: switch, bitswap: bitswap)

proc start*(_: type Dagger, address: MultiAddress): Future[Dagger] {.async.} =
  result = await Dagger.start(@[address])

proc start*(_: type Dagger): Future[Dagger] {.async.} =
  result = await Dagger.start(@[])

proc connect*(peer: Dagger, info: PeerInfo) {.async.} =
  await peer.bitswap.connect(info)

proc add*(peer: Dagger, input: File): Future[Cid] {.async.} =
  let obj = createObject(input)
  peer.repo.store(obj)
  result = obj.cid

proc get*(peer: Dagger, identifier: Cid, output: File) {.async.} =
  let obj = await peer.bitswap.retrieve(identifier)
  if obj.isSome:
    obj.get().writeToFile(output)

proc stop*(peer: Dagger) {.async.} =
  await peer.switch.stop()
