import std/times

import pkg/unittest2
import pkg/storage/systemclock

suite "SystemClock":
  test "Should get now":
    let clock = SystemClock.new()

    let expectedNow = times.now().utc
    let now = clock.now()

    check now == expectedNow.toTime().toUnix()
