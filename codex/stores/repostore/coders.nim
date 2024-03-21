## Nim-Codex
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/libp2p/cid

import ./types
import ../../errors
import ../../merkletree
import ../../utils/genericcoders

proc encode*(t: Cid): seq[byte] = t.data.buffer
proc decode*(T: type Cid, bytes: seq[byte]): ?!Cid = Cid.init(bytes).mapFailure

proc encode*(t: QuotaUsage): seq[byte] = t.autoencode
proc decode*(T: type QuotaUsage, bytes: seq[byte]): ?!T = T.autodecode(bytes)

proc encode*(t: BlockMetadata): seq[byte] = t.autoencode
proc decode*(T: type BlockMetadata, bytes: seq[byte]): ?!T = T.autodecode(bytes)

proc encode*(t: LeafMetadata): seq[byte] = t.autoencode
proc decode*(T: type LeafMetadata, bytes: seq[byte]): ?!T = T.autodecode(bytes)

proc encode*(t: DeleteResult): seq[byte] = t.autoencode
proc decode*(T: type DeleteResult, bytes: seq[byte]): ?!T = T.autodecode(bytes)

proc encode*(t: StoreResult): seq[byte] = t.autoencode
proc decode*(T: type StoreResult, bytes: seq[byte]): ?!T = T.autodecode(bytes)
