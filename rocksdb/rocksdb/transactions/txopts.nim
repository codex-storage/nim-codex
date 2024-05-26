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
  TransactionOptionsPtr* = ptr rocksdb_transaction_options_t

  TransactionOptionsRef* = ref object
    cPtr: TransactionOptionsPtr

proc newTransactionOptions*(): TransactionOptionsRef =
  TransactionOptionsRef(cPtr: rocksdb_transaction_options_create())

proc isClosed*(txOpts: TransactionOptionsRef): bool {.inline.} =
  txOpts.cPtr.isNil()

proc cPtr*(txOpts: TransactionOptionsRef): TransactionOptionsPtr =
  doAssert not txOpts.isClosed()
  txOpts.cPtr

# TODO: Add setters and getters for backup options properties.

proc defaultTransactionOptions*(): TransactionOptionsRef {.inline.} =
  newTransactionOptions()
  # TODO: set prefered defaults

proc close*(txOpts: TransactionOptionsRef) =
  if not txOpts.isClosed():
    rocksdb_transaction_options_destroy(txOpts.cPtr)
    txOpts.cPtr = nil
