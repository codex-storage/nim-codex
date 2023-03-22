import std/times
import std/unittest

import codex/systemclock

suite "SystemClock":
  test "Should get now":
    let clock = SystemClock.new()

    let expectedNow = times.now().utc
    let now = clock.now()

    check now == expectedNow.toTime().toUnix()
