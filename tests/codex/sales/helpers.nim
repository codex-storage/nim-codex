import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import pkg/codex/sales/reservations
import ../helpers

export checksuite

proc allAvailabilities*(r: Reservations): Future[seq[Availability]] {.async.} =
  var ret: seq[Availability] = @[]
  without availabilities =? (await r.availabilities), err:
    raiseAssert "failed to get availabilities, error: " & err.msg
  for a in availabilities:
    if availability =? (await a):
      ret.add availability
  return ret
