import pkg/unittest2

import codex/clock
import ./helpers

suite "Clock":
  proc testConversion(seconds: SecondsSince1970) =
    let asBytes = seconds.toBytes

    let restored = asBytes.toSecondsSince1970

    check restored == seconds

  test "SecondsSince1970 should support bytes conversions":
    let secondsToTest: seq[int64] = @[int64.high, int64.low, 0, 1, 12345, -1, -12345]

    for seconds in secondsToTest:
      testConversion(seconds)
