import pkg/protobuf_serialization
import pkg/stew/byteutils
import pkg/stint
import pkg/nitro
import pkg/questionable
import pkg/upraises
import ./bitswap

export PricingMessage
export StateChannelUpdate

export stint
export nitro

push: {.upraises: [].}

type
  Pricing* = object
    address*: EthAddress
    price*: UInt256

func init*(_: type PricingMessage, pricing: Pricing): PricingMessage =
  PricingMessage(
    address: @(pricing.address.toArray),
    price: @(pricing.price.toBytesBE)
  )

func parse(_: type EthAddress, bytes: seq[byte]): ?EthAddress =
  var address: array[20, byte]
  if bytes.len != address.len:
    return EthAddress.none
  for i in 0..<address.len:
    address[i] = bytes[i]
  EthAddress(address).some

func parse(_: type UInt256, bytes: seq[byte]): ?UInt256 =
  if bytes.len > 32:
    return UInt256.none
  UInt256.fromBytesBE(bytes).some

func init*(_: type Pricing, message: PricingMessage): ?Pricing =
  without address =? EthAddress.parse(message.address) and
          price =? UInt256.parse(message.price):
    return Pricing.none
  Pricing(address: address, price: price).some

func init*(_: type StateChannelUpdate, state: SignedState): StateChannelUpdate =
  StateChannelUpdate(update: state.toJson.toBytes)

proc init*(_: type SignedState, update: StateChannelUpdate): ?SignedState =
  SignedState.fromJson(string.fromBytes(update.update))
