## Nim-Dagger
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import pkg/libp2p
import pkg/questionable

template EmptyDigests*: untyped =
  var
    emptyDigests {.global, threadvar.}:
      array[CIDv0..CIDv1, Table[MultiCodec, MultiHash]]

  once:
    emptyDigests = [
      CIDv0: {
        multiCodec("sha2-256"): Cid
        .init("bafybeihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
        .get()
        .mhash
        .get()
      }.toTable,
      CIDv1: {
        multiCodec("sha2-256"): Cid
        .init("QmdfTbBqBPQ7VNxZEYEj14VmRuZBkqFbiwReogJgS1zR1n")
        .get()
        .mhash
        .get()
      }.toTable,
    ]

  emptyDigests

type
  Manifest* = object of RootObj
    rootHash*: ?Cid
    blockSize*: int
    blocks*: seq[Cid]
    version*: CidVersion
    hcodec*: MultiCodec
    codec*: MultiCodec
