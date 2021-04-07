import pkg/protobuf_serialization
import pkg/nitro
import pkg/questionable
import pkg/upraises

import_proto3 "payments.proto"

export PricingMessage

export nitro

push: {.upraises: [].}

type
  Pricing* = object
    address*: EthAddress
    asset*: EthAddress
    price*: UInt256

func init*(_: type PricingMessage, pricing: Pricing): PricingMessage =
  PricingMessage(
    address: @(pricing.address.toArray),
    asset: @(pricing.asset.toArray),
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
  let address = EthAddress.parse(message.address)
  let asset = EThAddress.parse(message.asset)
  let price = UInt256.parse(message.price)
  if address.isNone or asset.isNone or price.isNone:
    return Pricing.none
  Pricing(address: address.get, asset: asset.get, price: price.get).some
