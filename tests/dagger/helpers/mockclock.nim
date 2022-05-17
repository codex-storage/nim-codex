import std/times
import dagger/clock

export clock

type
  MockClock* = ref object of Clock
    time: SecondsSince1970

func new*(_: type MockClock,
          time: SecondsSince1970 = getTime().toUnix): MockClock =
  MockClock(time: time)

func set*(clock: MockClock, time: SecondsSince1970) =
  clock.time = time

func advance*(clock: MockClock, seconds: int64) =
  clock.time += seconds

method now*(clock: MockClock): SecondsSince1970 =
  clock.time
