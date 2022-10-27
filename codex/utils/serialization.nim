## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}

import std/strutils

import pkg/libp2p
import pkg/libp2p/crypto/secp
import pkg/libp2p/crypto/crypto
import pkg/libp2pdht
import pkg/confutils/defs
import pkg/confutils/std/net
import confutils/toml/std/uri
import pkg/chronicles
import pkg/toml_serialization
import pkg/json_serialization
import pkg/stew/byteutils
import pkg/ethers

import ../conf

proc writeValue*(
  writer: var TomlWriter,
  value: SignedPeerRecord)
  {.raises: [Defect, SerializationError, IOError].} =
  writer.writeValue(value.toUri)

proc readValue*(
  r: var TomlReader,
  value: var SignedPeerRecord)
  {.raises: [Defect, SerializationError, IOError].} =
  try:
    discard value.fromURI(r.readValue(string))
  except CatchableError as exc:
    raise newException(Defect, exc.msg)

proc writeValue*(
  writer: var TomlWriter,
  value: secp.SkPublicKey)
  {.raises: [Defect, SerializationError, IOError].} =
  writer.writeValue(value.getBytes().to0xHex)

proc readValue*(
  r: var TomlReader,
  value: var secp.SkPublicKey)
  {.raises: [Defect, SerializationError, IOError].} =
    try:
      value = secp.SkPublicKey
      .init(r.readValue(string))
      .expect("Hex encoded byte array expected for public key")
    except ValueError as exc:
      raise newException(SerializationError, exc.msg)

proc writeValue*(
  writer: var TomlWriter,
  value: crypto.PublicKey)
  {.raises: [Defect, SerializationError, IOError].} =
  writer.writeValue(value.getBytes().get.to0xHex)

proc readValue*(
  r: var TomlReader,
  value: var crypto.PublicKey)
  {.raises: [Defect, SerializationError, IOError].} =
    try:
      value = crypto.PublicKey
      .init(r.readValue(string))
      .expect("Hex encoded byte array expected for public key")
    except ValueError as exc:
      raise newException(SerializationError, exc.msg)

proc writeValue*(
  writer: var TomlWriter,
  value: MultiAddress)
  {.raises: [Defect, SerializationError, IOError].} =
  writer.writeValue($value)

proc writeValue*(
  writer: var TomlWriter,
  value: seq[MultiAddress])
  {.raises: [Defect, SerializationError, IOError].} =
  writer.writeIterable(value)

proc readValue*(
  r: var TomlReader,
  value: var MultiAddress)
  {.raises: [Defect, SerializationError, IOError].} =
  try:
    value = MultiAddress.init(r.readValue(string)).get()
  except ValueError as exc:
    raise newException(SerializationError, exc.msg)

proc writeValue*(
  writer: var TomlWriter,
  value: LogLevel)
  {.raises: [Defect, SerializationError, IOError].} =
  writer.writeValue($value)

proc readValue*(
  r: var TomlReader,
  value: var LogLevel)
  {.raises: [Defect, SerializationError, IOError].} =
  try:
    value = strutils.parseEnum[LogLevel](r.readValue(string))
  except ValueError as exc:
    raise newException(SerializationError, exc.msg)

proc writeValue*(
  writer: var TomlWriter,
  value: LogKind)
  {.raises: [Defect, SerializationError, IOError].} =
  writer.writeValue($value)

proc readValue*(
  r: var TomlReader,
  value: var LogKind)
  {.raises: [Defect, SerializationError, IOError].} =
  try:
    value = strutils.parseEnum[LogKind](r.readValue(string))
  except ValueError as exc:
    raise newException(SerializationError, exc.msg)

proc writeValue*(
  writer: var TomlWriter,
  value: ValidIpAddress)
  {.raises: [Defect, SerializationError, IOError].} =
  writeStackTrace()
  writer.writeValue($value)

proc readValue*(
  r: var TomlReader,
  value: var ValidIpAddress)
  {.raises: [Defect, SerializationError, IOError].} =
  try:
    value = ValidIpAddress.init(r.readValue(string))
  except ValueError as exc:
    raise newException(SerializationError, exc.msg)

proc writeValue*(
  writer: var TomlWriter,
  value: Option[string])
  {.raises: [Defect, SerializationError, IOError].} =
  if value.isSome:
    writer.writeValue(value.get)
  else:
    writer.writeValue("")

proc readValue*(
  r: var TomlReader,
  value: var Option[string])
  {.raises: [Defect, SerializationError, IOError].} =
  try:
    value = r.readValue(string).some
  except ValueError as exc:
    raise newException(SerializationError, exc.msg)

proc writeValue*(
  writer: var TomlWriter,
  value: Option[LogLevel])
  {.raises: [Defect, SerializationError, IOError].} =
  if value.isSome:
    writer.writeValue($value.get)
  else:
    writer.writeValue("INFO")

proc readValue*(
  r: var TomlReader,
  value: var Option[LogLevel])
  {.raises: [Defect, SerializationError, IOError].} =
  try:
    value = strutils.parseEnum[LogLevel](r.readValue(string)).some
  except ValueError as exc:
    raise newException(SerializationError, exc.msg)

proc writeValue*(
  writer: var TomlWriter,
  value: Port)
  {.raises: [Defect, SerializationError, IOError].} =
  writer.writeValue(value.int)

proc readValue*(
  r: var TomlReader,
  value: var Port)
  {.raises: [Defect, SerializationError, IOError].} =
  try:
    value = Port r.readValue(int)
  except ValueError as exc:
    raise newException(Defect, exc.msg)

proc writeValue*(
  writer: var TomlWriter,
  value: EthAddress)
  {.raises: [Defect, SerializationError, IOError].} =
  writer.writeValue($value)

proc readValue*(
  r: var TomlReader,
  value: var EthAddress)
  {.raises: [Defect, SerializationError, IOError].} =
  try:
    value = EthAddress.init(r.readValue(string)).get()
  except ValueError as exc:
    raise newException(SerializationError, exc.msg)

template writeValue*(writer: var TomlWriter,
                     value: TypedInputFile|InputFile|InputDir|OutPath|OutDir|OutFile) =
  writer.writeValue(string value)

template readValue*(reader: var TomlReader,
                     value: var TypedInputFile|InputFile|InputDir|OutPath|OutDir|OutFile) =
  value = typeof(value) reader.readValue(string)
