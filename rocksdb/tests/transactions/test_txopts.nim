# Nim-RocksDB
# Copyright 2024 Status Research & Development GmbH
# Licensed under either of
#
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * GPL license, version 2.0, ([LICENSE-GPLv2](LICENSE-GPLv2) or https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
#
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2,
  ../../rocksdb/transactions/txopts

suite "TransactionOptionsRef Tests":

  test "Test newTransactionOptions":
    var txOpts = newTransactionOptions()

    check not txOpts.cPtr.isNil()

    txOpts.close()

  test "Test defaultTransactionOptions":
    var txOpts = defaultTransactionOptions()

    check not txOpts.cPtr.isNil()

    txOpts.close()

  test "Test close":
    var txOpts = defaultTransactionOptions()

    check not txOpts.isClosed()
    txOpts.close()
    check txOpts.isClosed()
    txOpts.close()
    check txOpts.isClosed()