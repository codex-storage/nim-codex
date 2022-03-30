## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options

import pkg/leopard
import pkg/stew/results

import ./types

type
  LeoBackend* = object of Backend
    encoder*: Option[LeoEncoder]
    decoder*: Option[LeoDecoder]

proc encode*(
  self: var LeoBackend,
  data,
  parity: var openArray[seq[byte]]): Result[void, cstring] =

  var encoder = if self.encoder.isNone:
      self.encoder = (? LeoEncoder.init(self.blockSize, self.K, self.M)).some
      self.encoder.get()
    else:
      self.encoder.get()

  encoder.encode(data, parity)

proc decode*(
  self: var LeoBackend,
  data,
  parity,
  recovered: var openArray[seq[byte]]): Result[void, cstring] =

  var decoder = if self.decoder.isNone:
      self.decoder = (? LeoDecoder.init(self.blockSize, self.K, self.M)).some
      self.decoder.get()
    else:
      self.decoder.get()

  decoder.decode(data, parity, recovered)

func destroy*(self: var LeoBackend) =
  if self.encoder.isSome:
    self.encoder.free()

  if self.decoder.isSome:
    self.decoder.free()

func init*(T: type LeoBackend, blockSize, buffers, parity: int): T =
  T(
    blockSize: blockSize,
    K: buffers,
    M: parity)
