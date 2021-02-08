import pkg/chronos
import pkg/libp2p/cid
import ../repo
import ./stream
import ./messages

type Exchange* = object
  repo: Repo
  stream: BitswapStream

proc want*(exchange: Exchange, cid: Cid) {.async.} =
  await exchange.stream.write(Message.want(cid))

proc send*(exchange: Exchange, obj: IpfsObject) {.async.} =
  await exchange.stream.write(Message.send(obj.data))

proc handlePayload(exchange: Exchange, message: Message) {.async.} =
  for bloc in message.payload:
    let obj = IpfsObject(data: bloc.data)
    exchange.repo.store(obj)

proc handleWants(exchange: Exchange, message: Message) {.async.} =
  for want in message.wantlist.entries:
    let cid = Cid.init(want.`block`).get()
    let obj = exchange.repo.retrieve(cid)
    if obj.isSome:
      await exchange.send(obj.get())

proc readLoop(exchange: Exchange) {.async.} =
  while true:
    let message = await exchange.stream.read()
    await exchange.handlePayload(message)
    await exchange.handleWants(message)

proc start*(_: type Exchange, repo: Repo, stream: BitswapStream): Exchange =
  let exchange = Exchange(repo: repo, stream: stream)
  asyncSpawn exchange.readLoop()
  exchange
