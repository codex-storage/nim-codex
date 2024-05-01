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
  ../../rocksdb/transactions/txdbopts

suite "TransactionDbOptionsRef Tests":

  test "Test newTransactionDbOptions":
    var txDbOpts = newTransactionDbOptions()

    check not txDbOpts.cPtr.isNil()

    txDbOpts.close()

  test "Test defaultTransactionDbOptions":
    var txDbOpts = defaultTransactionDbOptions()

    check not txDbOpts.cPtr.isNil()

    txDbOpts.close()

  test "Test close":
    var txDbOpts = defaultTransactionDbOptions()

    check not txDbOpts.isClosed()
    txDbOpts.close()
    check txDbOpts.isClosed()
    txDbOpts.close()
    check txDbOpts.isClosed()