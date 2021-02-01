import pkg/chronos
import pkg/libp2p/peerinfo
import pkg/libp2p/multiaddress
import ./ipfs/p2p/switch
import ./ipfs/repo
import ./ipfs/chunking
import ./ipfs/bitswap

export peerinfo except IPFS
export multiaddress except IPFS

type
  Ipfs* = ref object
    repo: Repo
    switch: Switch
    bitswap: Bitswap

proc info*(ipfs: Ipfs): PeerInfo =
  ipfs.switch.peerInfo

proc start*(_: type Ipfs, addresses: seq[MultiAddress]): Future[Ipfs] {.async.} =
  let repo = Repo()
  let switch = Switch.create()
  let bitswap = Bitswap.start(switch, repo)
  switch.peerInfo.addrs.add(addresses)
  discard await switch.start()
  result = Ipfs(repo: repo, switch: switch, bitswap: bitswap)

proc start*(_: type Ipfs, address: MultiAddress): Future[Ipfs] {.async.} =
  result = await Ipfs.start(@[address])

proc start*(_: type Ipfs): Future[Ipfs] {.async.} =
  result = await Ipfs.start(@[])

proc connect*(peer: Ipfs, info: PeerInfo) {.async.} =
  await peer.bitswap.connect(info)

proc add*(peer: Ipfs, input: File): Future[Cid] {.async.} =
  let obj = createObject(input)
  peer.repo.store(obj)
  result = obj.cid

proc get*(peer: Ipfs, identifier: Cid, output: File) {.async.} =
  let obj = await peer.bitswap.retrieve(identifier)
  if obj.isSome:
    obj.get().writeToFile(output)

proc stop*(peer: Ipfs) {.async.} =
  await peer.switch.stop()
