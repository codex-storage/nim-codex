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
import std/options

import pkg/libp2p
import pkg/stew/shims/net

func remapAddr*(
    address: MultiAddress,
    ip: Option[IpAddress] = IpAddress.none,
    port: Option[Port] = Port.none
): MultiAddress =
  ## Remap addresses to new IP and/or Port
  ##

  var
    parts = ($address).split("/")

  parts[2] = if ip.isSome:
      $ip.get
    else:
      parts[2]

  parts[4] = if port.isSome:
      $port.get
    else:
      parts[4]

  MultiAddress.init(parts.join("/"))
    .expect("Should construct multiaddress")
