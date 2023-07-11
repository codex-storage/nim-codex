import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/upraises

type
  OnSuccess*[T] = proc(val: T) {.gcsafe, upraises: [].}
  OnCancelled* = proc(err: ref CancelledError) {.gcsafe, upraises: [].}
  OnError* = proc(err: ref CatchableError) {.gcsafe, upraises: [].}

proc syncify*(future: Future[void],
              onCancelled: OnCancelled,
              onError: OnError) =

  proc catchErrors {.async.} =
    try:
      await future
    except CancelledError as e:
      onCancelled(e)
      # raise e
    except CatchableError as e:
      onError(e)

  asyncSpawn catchErrors()

proc syncify*[T](future: Future[?!T],
                 onSuccess: OnSuccess,
                 onCancelled: OnCancelled,
                 onError: OnError) =

  proc catchErrors {.async.} =
    try:
      without val =? (await future), err:
        onError(err)
      onSuccess(val)
    except CancelledError as e:
      onCancelled(e)
    except CatchableError as e:
      onError(e)

  asyncSpawn catchErrors()

proc syncify*(future: Future[?!void],
              onCancelled: OnCancelled,
              onError: OnError) =

  proc catchErrors {.async.} =
    try:
      if err =? (await future).errorOption:
        onError(err)
    except CancelledError as e:
      onCancelled(e)
    except CatchableError as e:
      onError(e)

  asyncSpawn catchErrors()

proc syncify*[T](future: Future[T],
                 onSuccess: OnSuccess,
                 onCancelled: OnCancelled,
                 onError: OnError) =

  proc catchErrors {.async.} =
    try:
      onSuccess(await future)
    except CancelledError as e:
      onCancelled(e)
    except CatchableError as e:
      onError(e)

  asyncSpawn catchErrors()
