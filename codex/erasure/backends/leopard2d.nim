## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options
from std/math import sqrt
import std/sequtils

import pkg/leopard
import pkg/stew/results

import ../backend

type
  LeoEncoderBackend2D* = ref object of EncoderBackend
    encoder1*: Option[LeoEncoder]
    encoder2*: Option[LeoEncoder]
    k1*, m1*, k2*, m2*: int

  LeoDecoderBackend2D* = ref object of DecoderBackend
    decoder1*: Option[LeoDecoder]
    decoder2*: Option[LeoDecoder]
    k1*, m1*, k2*, m2*: int

method encode*(
  self: LeoEncoderBackend2D,
  data,
  parity: var openArray[seq[byte]]): Result[void, cstring] =
  ## Encode using 2D RS encoding.

  if parity.len == 0:
    return ok()

  var encoder1 = if self.encoder1.isNone:
      self.encoder1 = (? LeoEncoder.init(
        self.blockSize,
        self.k1,
        self.m1)).some
      self.encoder1.get()
    else:
      self.encoder1.get()

  for i in 0 ..< self.k2:
    #encoder1.encode(data[i*self.k1 ..< (i+1)+self.k1], parity[i*self.m1 ..< (i+1)*self.m1])
    var
      data1 = newSeq[seq[byte]](self.k1)
      parity1 = newSeq[seq[byte]](self.m1)
    for j in 0 ..< self.k1:
      shallowCopy(data1[j], data[i*self.k1 + j])
    for j in 0 ..< self.m1:
      shallowCopy(parity1[j], parity[i*self.m1 + j])
    let res = encoder1.encode(data1, parity1)
    if res.isErr:
      return res

  var encoder2 = if self.encoder2.isNone:
      self.encoder2 = (? LeoEncoder.init(
        self.blockSize,
        self.k1,
        self.m1)).some
      self.encoder2.get()
    else:
      self.encoder2.get()

  for i in 0 ..< self.k1 + self.m1:
    var
      data2 = newSeq[seq[byte]](self.k2)
      parity2 = newSeq[seq[byte]](self.m2)
    for j in 0 ..< self.k2:
      if i < self.k1:
        shallowCopy(data2[j], data[i + self.k1 * j])
      else:
        shallowCopy(data2[j], parity[i + self.m1 * j])
    for j in 0 ..< self.m2:
      shallowCopy(parity2[j], parity[self.k2 * self.m1 + i + self.m2 * j])
    let res = encoder2.encode(data2, parity2)
    if res.isErr:
      return res

  ok()

method decode*(
  self: LeoDecoderBackend2D,
  data,
  parity,
  recovered: var openArray[seq[byte]]): Result[void, cstring] =
  ## Decode 2D RS encoded data. Only do one simple recovery attempt,
  ## since underlying encoder misses recovery of parity segments.

  var decoder1 = if self.decoder1.isNone:
      self.decoder1 = (? LeoDecoder.init(
        self.blockSize,
        self.k1,
        self.m1)).some
      self.decoder1.get()
    else:
      self.decoder1.get()

  var
    missing = 0
    repaired = 0

  for i in 0 ..< self.k2:
    var
      data1 = newSeq[seq[byte]](self.k1)
      parity1 = newSeq[seq[byte]](self.m1)
      recovered1 = newSeq[seq[byte]](self.k1)
    for j in 0 ..< self.k1:
      shallowCopy(data1[j], data[i*self.k1 + j])
      shallowCopy(recovered1[j], recovered[i*self.k1 + j])
      if data1[j].len == 0:
        missing += 1
    for j in 0 ..< self.m1:
      shallowCopy(parity1[j], parity[i*self.m1 + j])
      if parity1[j].len == 0:
        missing += 1

    let res = decoder1.decode(data1, parity1, recovered1)
    if res.isOk():
      #missing parity is not recovered by the Leopard decode API
      for j in 0 ..< self.k1:
        if data1[j].len == 0:
          repaired += 1

  if missing == repaired:
    ok()
  else:
    err("can't repair in a single round")

method release*(self: LeoEncoderBackend2D) =
  if self.encoder1.isSome:
    self.encoder1.get().free()
  if self.encoder2.isSome:
    self.encoder2.get().free()

method release*(self: LeoDecoderBackend2D) =
  if self.decoder1.isSome:
    self.decoder1.get().free()
  if self.decoder2.isSome:
    self.decoder2.get().free()

func new*(
  T: type LeoEncoderBackend2D,
  blockSize,
  k1,
  m1,
  k2,
  m2: int): T =
  ## Initialize 2D encoder.
  T(
    blockSize: blockSize,
    buffers: k1*k2, # store K and M for compatibility
    parity: (k1+m1) * (k2*m2) - k1*k2,
    k1: k1,
    m1: m1,
    k2: k2,
    m2: m2
  )

func new*(
  T: type LeoEncoderBackend2D,
  blockSize,
  k,
  m: int): T =
  ## Initialize 2D encoder using "product" k and m, assuming these are squares.
  ## TODO: check that params are actually squares.
  let
    k1, k2 = sqrt(k.float).int
    m1, m2 = sqrt((k + m).float).int - k1
  T(
    blockSize: blockSize,
    buffers: k,
    parity: m,
    k1: k1,
    m1: m1,
    k2: k2,
    m2: m2
  )

func new*(
  T: type LeoDecoderBackend2D,
  blockSize,
  k1,
  m1,
  k2,
  m2: int): T =
  T(
    blockSize: blockSize,
    buffers: k1*k2, # store K and M for compatibility
    parity: (k1+m1) * (k2*m2) - k1*k2,
    k1: k1,
    m1: m1,
    k2: k2,
    m2: m2
  )

## TODO: initalize using sqrt, failing if not squares
func new*(
  T: type LeoDecoderBackend2D,
  blockSize,
  k,
  m: int): T =
  let
    k1, k2 = sqrt(k.float).int
    m1, m2 = sqrt((k + m).float).int - k1
  ## TODO check
  T(
    blockSize: blockSize,
    buffers: k,
    parity: m,
    k1: k1,
    m1: m1,
    k2: k2,
    m2: m2
  )
