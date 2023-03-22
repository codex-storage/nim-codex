## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/chronos
import pkg/libp2p
import pkg/chronicles
import pkg/questionable/results
import pkg/contractabi/address as ca

import ./stpproto
import ../discovery
import ../formats

const
  Codec* = "/dagger/storageproofs/1.0.0"
  MaxMessageSize* = 1 shl 22 # 4MB

logScope:
  topics = "dagger storageproofs network"

type
  TagsHandler* = proc(msg: TagsMessage):
    Future[void] {.raises: [Defect], gcsafe.}

  StpNetwork* = ref object of LPProtocol
    switch*: Switch
    discovery*: Discovery
    tagsHandle*: TagsHandler

proc uploadTags*(
  self: StpNetwork,
  cid: Cid,
  indexes: seq[int],
  tags: seq[seq[byte]],
  host: ca.Address): Future[?!void] {.async.} =
  # Upload tags to `host`
  #

  var msg = TagsMessage(cid: cid.data.buffer)
  for i in indexes:
    msg.tags.add(Tag(idx: i, tag: tags[i]))

  let
    peers = await self.discovery.find(host)
    connFut = await one(peers.mapIt(
      self.switch.dial(
        it.data.peerId,
        it.data.addresses.mapIt( it.address ),
        @[Codec])))
    conn = await connFut

  try:
    await conn.writeLp(msg.encode)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "Exception submitting tags", cid, exc = exc.msg
    return failure(exc.msg)
  finally:
    await conn.close()

  return success()

method init*(self: StpNetwork) =
  ## Perform protocol initialization
  ##

  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let
        msg = await conn.readLp(MaxMessageSize)
        res = TagsMessage.decode(msg)

      if not self.tagsHandle.isNil:
        if res.isOk and res.get.tags.len > 0:
          await self.tagsHandle(res.get)
    except CatchableError as exc:
      trace "Exception handling Storage Proofs message", exc = exc.msg
    finally:
      await conn.close()

  self.handler = handle
  self.codec = Codec

proc new*(
  T: type StpNetwork,
  switch: Switch,
  discovery: Discovery): StpNetwork =
  let
    self = StpNetwork(
      switch: switch,
      discovery: discovery)

  self.init()
  self
