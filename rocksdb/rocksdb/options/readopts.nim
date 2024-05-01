# Nim-RocksDB
# Copyright 2024 Status Research & Development GmbH
# Licensed under either of
#
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * GPL license, version 2.0, ([LICENSE-GPLv2](LICENSE-GPLv2) or https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
#
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  ../lib/librocksdb

type
  ReadOptionsPtr* = ptr rocksdb_readoptions_t

  ReadOptionsRef* = ref object
    cPtr: ReadOptionsPtr

proc newReadOptions*(): ReadOptionsRef =
  ReadOptionsRef(cPtr: rocksdb_readoptions_create())

proc isClosed*(readOpts: ReadOptionsRef): bool {.inline.} =
  readOpts.cPtr.isNil()

proc cPtr*(readOpts: ReadOptionsRef): ReadOptionsPtr =
  doAssert not readOpts.isClosed()
  readOpts.cPtr

# TODO: Add setters and getters for read options properties.

proc defaultReadOptions*(): ReadOptionsRef {.inline.} =
  newReadOptions()
  # TODO: set prefered defaults

proc close*(readOpts: ReadOptionsRef) =
  if not readOpts.isClosed():
    rocksdb_readoptions_destroy(readOpts.cPtr)
    readOpts.cPtr = nil
