import std/times

import codex/systemclock

import ../asynctest
import ./helpers

asyncchecksuite "SystemClock":
  test "Should get now":
    let clock = SystemClock.new()

    let expectedNow = times.now().utc
    let now = (await clock.now())

    check now == expectedNow.toTime().toUnix()
