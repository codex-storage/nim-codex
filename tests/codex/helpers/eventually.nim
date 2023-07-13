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

template always*(condition: untyped, timeout = 50.millis): bool =
  proc loop: Future[bool] {.async.} =
    let start = Moment.now()
    while true:
      if not condition:
        return false
      if Moment.now() > (start + timeout):
        return true
      else:
        await sleepAsync(1.millis)
  await loop()
