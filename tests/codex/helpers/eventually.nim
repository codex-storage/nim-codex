import pkg/chronos

template eventually*(condition: untyped, timeout = 5.seconds): bool =
  proc loop: Future[bool] {.async.} =
    let start = Moment.now()
    while true:
      if condition:
        return true
      if Moment.now() > (start + timeout):
        return false
      else:
        await sleepAsync(1.millis)
  await loop()
