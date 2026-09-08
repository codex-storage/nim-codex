import std/base64

import pkg/libp2p/[multicodec, multiaddress]
import pkg/stew/byteutils
import pkg/unittest2

const
  MixTransportPayloadHex =
    "8a6571e8665fb1c894215f97d6a244591b655b1f5fd5ff7f928ef8b74aa66c5f" &
    "03907bc5a41bec7c5ba11f8dfe6c7f779328d2d5bb48c9a978a11e09f3fbf61b3e"
  EncodedMixTransportPayload =
    "imVx6GZfsciUIV-X1qJEWRtlWx9f1f9_ko74t0qmbF8DkHvFpBvsfFuhH43-bH93" &
    "kyjS1btIyal4oR4J8_v2Gz4="
  MixTransportAddress =
    "/ip4/127.0.0.1/tcp/8001/mix-transport/" & EncodedMixTransportPayload

suite "mix-transport multiaddress extension":
  test "encodes and decodes the address":
    let address = MultiAddress.init(MixTransportAddress).expect("valid mix address")

    check $address == MixTransportAddress

    let payload = address.getProtocolArgument(multiCodec("mix-transport"))
    check payload.isOk
    check payload.get == hexToSeqByte(MixTransportPayloadHex)

    let decoded = MultiAddress.init(address.data.buffer)
    check decoded.isOk
    check $decoded.get == MixTransportAddress

  test "uses URL-safe base64 for the key payload":
    let payload = hexToSeqByte(MixTransportPayloadHex)

    check base64.encode(payload, safe = true) == EncodedMixTransportPayload
    check '/' notin EncodedMixTransportPayload

  test "rejects invalid base64":
    check MultiAddress.init("/ip4/127.0.0.1/tcp/8001/mix-transport/not_base64!").isErr

  test "rejects an incorrectly sized payload":
    let encoded = base64.encode(newSeq[byte](64), safe = true)

    check MultiAddress.init("/ip4/127.0.0.1/tcp/8001/mix-transport/" & encoded).isErr

  test "rejects an invalid libp2p public key":
    let encoded = base64.encode(newSeq[byte](65), safe = true)

    check MultiAddress.init("/ip4/127.0.0.1/tcp/8001/mix-transport/" & encoded).isErr
