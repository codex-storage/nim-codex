## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/questionable/results
import pkg/libp2p/protobuf/minprotobuf

type
  TauZeroMessage* = object
    name*: seq[byte]
    n*: int64
    u*: seq[seq[byte]]

  TauMessage* = object
    t*: TauZeroMessage
    signature*: seq[byte]

  PubKeyMessage* = object
    signkey*: seq[byte]
    key*: seq[byte]

  PorMessage* = object
    tau*: TauMessage
    spk*: PubKeyMessage
    authenticators*: seq[seq[byte]]

  ProofMessage* = object
    mu*: seq[seq[byte]]
    sigma*: seq[byte]

  PoREnvelope* = object
    por*: PorMessage
    proof*: ProofMessage

func write*(pb: var ProtoBuffer, field: int, value: TauZeroMessage) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.name)
  ipb.write(2, value.n.uint64)

  for u in value.u:
    ipb.write(3, u)

  ipb.finish()
  pb.write(field, ipb)

func write*(pb: var ProtoBuffer, field: int, value: TauMessage) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.t)
  ipb.write(2, value.signature)
  ipb.finish()

  pb.write(field, ipb)

func write*(pb: var ProtoBuffer, field: int, value: PubKeyMessage) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.signkey)
  ipb.write(2, value.key)
  ipb.finish()
  pb.write(field, ipb)

func write*(pb: var ProtoBuffer, field: int, value: PorMessage) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.tau)
  ipb.write(2, value.spk)

  for a in value.authenticators:
    ipb.write(3, a)

  ipb.finish()
  pb.write(field, ipb)

func encode*(msg: PorMessage): seq[byte] =
  var ipb = initProtoBuffer()
  ipb.write(1, msg.tau)
  ipb.write(2, msg.spk)

  for a in msg.authenticators:
    ipb.write(3, a)

  ipb.finish
  ipb.buffer

func write*(pb: var ProtoBuffer, field: int, value: ProofMessage) =
  var ipb = initProtoBuffer()
  for mu in value.mu:
    ipb.write(1, mu)

  ipb.write(2, value.sigma)
  ipb.finish()
  pb.write(field, ipb)

func encode*(message: PoREnvelope): seq[byte] =
  var ipb = initProtoBuffer()
  ipb.write(1, message.por)
  ipb.write(2, message.proof)
  ipb.finish
  ipb.buffer

proc decode*(_: type TauZeroMessage, pb: ProtoBuffer): ProtoResult[TauZeroMessage] =
  var
    value = TauZeroMessage()

  discard ? pb.getField(1, value.name)

  var val: uint64
  discard ? pb.getField(2, val)
  value.n = val.int64

  var bytes: seq[seq[byte]]
  discard ? pb.getRepeatedField(3, bytes)

  for b in bytes:
    value.u.add(b)

  ok(value)

proc decode*(_: type TauMessage, pb: ProtoBuffer): ProtoResult[TauMessage] =
  var
    value = TauMessage()
    ipb: ProtoBuffer

  discard ? pb.getField(1, ipb)

  value.t = ? TauZeroMessage.decode(ipb)

  discard ? pb.getField(2, value.signature)

  ok(value)

proc decode*(_: type PubKeyMessage, pb: ProtoBuffer): ProtoResult[PubKeyMessage] =
  var
    value = PubKeyMessage()

  discard ? pb.getField(1, value.signkey)
  discard ? pb.getField(2, value.key)

  ok(value)

proc decode*(_: type PorMessage, pb: ProtoBuffer): ProtoResult[PorMessage] =
  var
    value = PorMessage()
    ipb: ProtoBuffer

  discard ? pb.getField(1, ipb)
  value.tau = ? TauMessage.decode(ipb)

  discard ? pb.getField(2, ipb)
  value.spk = ? PubKeyMessage.decode(ipb)

  var
    bytes: seq[seq[byte]]

  discard ? pb.getRepeatedField(3, bytes)

  for b in bytes:
    value.authenticators.add(b)

  ok(value)

proc decode*(_: type PorMessage, msg: seq[byte]): ProtoResult[PorMessage] =
  PorMessage.decode(initProtoBuffer(msg))

proc decode*(_: type ProofMessage, pb: ProtoBuffer): ProtoResult[ProofMessage] =
  var
    value = ProofMessage()

  discard ? pb.getField(1, value.mu)
  discard ? pb.getField(2, value.sigma)

  ok(value)

func decode*(_: type PoREnvelope, msg: openArray[byte]): ?!PoREnvelope =
  var
    value = PoREnvelope()
    pb = initProtoBuffer(msg)

  discard ? pb.getField(1, ? value.por.decode)
  discard ? pb.getField(2, ? value.proof.decode)

  ok(value)
