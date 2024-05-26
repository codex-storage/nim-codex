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
  ../../rocksdb/options/writeopts

suite "WriteOptionsRef Tests":

  test "Test newWriteOptions":
    var writeOpts = newWriteOptions()

    check not writeOpts.cPtr.isNil()

    writeOpts.close()

  test "Test defaultWriteOptions":
    var writeOpts = defaultWriteOptions()

    check not writeOpts.cPtr.isNil()

    writeOpts.close()

  test "Test close":
    var writeOpts = defaultWriteOptions()

    check not writeOpts.isClosed()
    writeOpts.close()
    check writeOpts.isClosed()
    writeOpts.close()
    check writeOpts.isClosed()