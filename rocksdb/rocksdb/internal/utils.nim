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
  std/locks,
  ../lib/librocksdb

const DEFAULT_COLUMN_FAMILY_NAME* = "default"

proc createLock*(): Lock =
  var lock = Lock()
  initLock(lock)
  lock

template bailOnErrors*(errors: cstring): auto =
  if not errors.isNil:
    let res = err($(errors))
    rocksdb_free(errors)
    return res
