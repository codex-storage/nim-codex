import pkg/chronos
import pkg/protobuf_serialization
import pkg/libp2p/stream/connection
import ./messages

export messages

const MaxMessageSize = 8 * 1024 * 1024

type
  BitswapStream* = ref object
    bytestream: LpStream
    messages: AsyncQueue[Message]

proc new*(t: type BitswapStream, bytestream: LpStream): BitswapStream =
  BitswapStream(bytestream: bytestream, messages: newAsyncQueue[Message](1))

proc readOnce(stream: BitswapStream) {.async.} =
  let encoded = await stream.bytestream.readLp(MaxMessageSize)
  let message = Protobuf.decode(encoded, Message)
  await stream.messages.put(message)

proc readLoop*(stream: BitswapStream) {.async.} =
  while true:
    try:
      await stream.readOnce()
    except LPStreamEOFError:
      break

proc write*(stream: BitswapStream, message: Message) {.async.} =
  let encoded = Protobuf.encode(message)
  await stream.bytestream.writeLp(encoded)

proc read*(stream: BitswapStream): Future[Message] {.async.} =
  result = await stream.messages.get()

proc close*(stream: BitswapStream) {.async.} =
  await stream.bytestream.close()
