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
  ../../rocksdb/columnfamily/cfopts

suite "ColFamilyOptionsRef Tests":

  test "Test newColFamilyOptions":
    var cfOpts = newColFamilyOptions()

    check not cfOpts.cPtr.isNil()
    # check not cfOpts.getCreateMissingColumnFamilies()

    cfOpts.setCreateMissingColumnFamilies(true)
    # check cfOpts.getCreateMissingColumnFamilies()

    cfOpts.close()

  test "Test defaultColFamilyOptions":
    var cfOpts = defaultColFamilyOptions()

    check not cfOpts.cPtr.isNil()
    # check cfOpts.getCreateMissingColumnFamilies()

    cfOpts.setCreateMissingColumnFamilies(false)
    # check not cfOpts.getCreateMissingColumnFamilies()

    cfOpts.close()

  test "Test close":
    var cfOpts = defaultColFamilyOptions()

    check not cfOpts.isClosed()
    cfOpts.close()
    check cfOpts.isClosed()
    cfOpts.close()
    check cfOpts.isClosed()