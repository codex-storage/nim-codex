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
import pkg/questionable
import pkg/questionable/results
import pkg/contractabi/address as cta

import ../discovery

import pkg/protobuf_serialization

import_proto3 "stp.proto"

export AuthExchangeMessage, StorageProofsMessage

const
  Codec* = "/dagger/storageproofs/1.0.0"

logScope:
  topics = "dagger storageproofs network"

type
  AuthenticatorsHandler* = proc(msg: AuthExchangeMessage):
    Future[void] {.raises: [Defect], gcsafe.}

  StpNetwork* = ref object of LPProtocol
    switch*: Switch
    discovery*: Discovery
    handleAuthenticators*: AuthenticatorsHandler

proc submitAuthenticators*(
  self: StpNetwork,
  cid: Cid,
  authenticators: seq[seq[byte]],
  host: cta.Address): Future[?!void] {.async.} =
  ## Submit authenticators to `host`
  ##

  var msg = AuthExchangeMessage(cid: cid.data.buffer)
  for a in authenticators:
    msg.authenticators.add(a)

  let
    peers = await self.discovery.find(host)
    connFut = await one(peers.mapIt(
      self.switch.dial(
        it.data.peerId,
        it.data.addresses.mapIt( it.address ),
        @[Codec])))
    conn = await connFut

  try:
    await conn.writeLp(Protobuf.encode(msg))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "Exception submitting authenticators", cid, exc = exc.msg
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
        msg = await conn.readLp(1024)
        message = Protobuf.decode(msg, StorageProofsMessage)

      if message.authenticators.authenticators.len > 0:
        await self.handleAuthenticators(message.authenticators)
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
