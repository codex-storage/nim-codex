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
  WriteOptionsPtr* = ptr rocksdb_writeoptions_t

  WriteOptionsRef* = ref object
    cPtr: WriteOptionsPtr

proc newWriteOptions*(): WriteOptionsRef =
  WriteOptionsRef(cPtr: rocksdb_writeoptions_create())

proc isClosed*(writeOpts: WriteOptionsRef): bool {.inline.} =
  writeOpts.cPtr.isNil()

proc cPtr*(writeOpts: WriteOptionsRef): WriteOptionsPtr =
  doAssert not writeOpts.isClosed()
  writeOpts.cPtr

# TODO: Add setters and getters for write options properties.

proc defaultWriteOptions*(): WriteOptionsRef {.inline.} =
  newWriteOptions()
  # TODO: set prefered defaults

proc close*(writeOpts: WriteOptionsRef) =
  if not writeOpts.isClosed():
    rocksdb_writeoptions_destroy(writeOpts.cPtr)
    writeOpts.cPtr = nil
