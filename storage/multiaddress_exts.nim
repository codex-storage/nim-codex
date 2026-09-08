import std/base64

import pkg/libp2p/crypto/[curve25519, secp]

const MixTransportPayloadSize = Curve25519KeySize + SkRawPublicKeySize

func validMixTransportPayload(payload: openArray[byte]): bool =
  if payload.len != MixTransportPayloadSize:
    return false

  SkPublicKey.init(payload.toOpenArray(Curve25519KeySize, payload.high)).isOk

proc mixTransportStB(s: string, vb: var VBuffer): bool =
  let decoded =
    try:
      base64.decode(s)
    except ValueError:
      return false

  if decoded.len != MixTransportPayloadSize or base64.encode(decoded, safe = true) != s:
    return false

  if not validMixTransportPayload(decoded.toOpenArrayByte(0, decoded.high)):
    return false

  vb.writeArray(decoded.toOpenArrayByte(0, decoded.high))
  true

proc mixTransportBtS(vb: var VBuffer, s: var string): bool =
  var payload: array[MixTransportPayloadSize, byte]
  if vb.readArray(payload) != MixTransportPayloadSize or
      not validMixTransportPayload(payload):
    return false

  s = base64.encode(payload, safe = true)
  true

proc mixTransportVB(vb: var VBuffer): bool =
  var payload: array[MixTransportPayloadSize, byte]
  vb.readArray(payload) == MixTransportPayloadSize and validMixTransportPayload(payload)

const
  TranscoderMixTransport = Transcoder(
    stringToBuffer: mixTransportStB,
    bufferToString: mixTransportBtS,
    validateBuffer: mixTransportVB,
  )
  AddressExts = [
    MAProtocol(
      mcodec: multiCodec("mix-transport"),
      kind: Fixed,
      size: MixTransportPayloadSize,
      coder: TranscoderMixTransport,
    )
  ]
