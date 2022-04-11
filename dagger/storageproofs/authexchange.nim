## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/libp2p
import pkg/chronicles

import pkg/protobuf_serialization

import_proto3 "authexchange.proto"

export AuthExchangeMessage

const
  Codec* = "/dagger/authexchange/1.0.0"

logScope:
  topics = "dagger authexchange network"

type
  AuthExchange* = ref object of LPProtocol
    switch*: Switch

func submitAuthenticators*(
  authenticators: seq[seq[byte]],
  hosts: seq[MultiAddress]): Future[void] =
  discard

method init*(b: AuthExchange) =
  ## Perform protocol initialization
  ##

  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    discard

  b.handler = handle
  b.codec = Codec

proc new*(
  T: type AuthExchange,
  switch: Switch): AuthExchange =

  AuthExchange(switch: switch)
