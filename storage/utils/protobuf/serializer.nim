## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/macros
import pkg/protobuf_serialization
import pkg/protobuf_serialization/pkg/results

type ProtobufDecodeError* = object
  msg*: string

proc `$`*(e: ProtobufDecodeError): string =
  e.msg

macro serializerForResult*(_: type Protobuf, Types: untyped): untyped =
  var stmts = newStmtList()
  for T in Types:
    let helperName = ident("decode" & $T)
    stmts.add quote do:
      proc encode*(c: `T`): seq[byte] =
        encode(Protobuf, c)

      proc `helperName`(buf: seq[byte]): `T` {.raises: [SerializationError].} =
        decode(Protobuf, buf, `T`)

      proc decode*(_: type `T`, buf: seq[byte]): Result[`T`, ProtobufDecodeError] =
        try:
          ok(`helperName`(buf))
        except SerializationError as exc:
          err(ProtobufDecodeError(msg: exc.msg))

  stmts
