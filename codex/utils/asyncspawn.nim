import pkg/chronos
import ../asyncyeah

proc asyncSpawn*(future: Future[void], ignore: type CatchableError) =
  proc ignoringError {.asyncyeah.} =
    try:
      await future
    except ignore:
      discard
  asyncSpawn ignoringError()

