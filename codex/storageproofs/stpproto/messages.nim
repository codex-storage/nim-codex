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

import ../../errors

type
  Tag* = object
    idx*: int64
    tag*: seq[byte]

  TagsMessage* = object
    cid*: seq[byte]
    tags*: seq[Tag]

func write*(pb: var ProtoBuffer, field: int, value: Tag) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.idx.uint64)
  ipb.write(2, value.tag)
  ipb.finish()
  pb.write(field, ipb)

func encode*(msg: TagsMessage): seq[byte] =
  var ipb = initProtoBuffer()
  ipb.write(1, msg.cid)

  for tag in msg.tags:
    ipb.write(2, tag)

  ipb.finish()
  ipb.buffer

func decode*(_: type Tag, pb: ProtoBuffer): ProtoResult[Tag] =
  var
    value = Tag()
    idx: uint64

  discard ? pb.getField(1, idx)
  value.idx = idx.int64

  discard ? pb.getField(2, value.tag)

  ok(value)

func decode*(_: type TagsMessage, msg: openArray[byte]): ProtoResult[TagsMessage] =
  var
    value = TagsMessage()
    pb = initProtoBuffer(msg)

  discard ? pb.getField(1, value.cid)

  var
    bytes: seq[seq[byte]]

  discard ? pb.getRepeatedField(2, bytes)

  for b in bytes:
    value.tags.add(? Tag.decode(initProtoBuffer(b)))

  ok(value)
