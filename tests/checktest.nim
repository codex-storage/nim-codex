import ./helpers

## Unit testing suite that calls checkTrackers in teardown to check for memory leaks using chronos trackers.
template checksuite*(name, body) =
  suite name:
    multisetup()

    teardown:
      checkTrackers()

    # Avoids GcUnsafe2 warnings with chronos
    # Copied from asynctest/templates.nim
    let suiteproc = proc =
      body

    suiteproc()

template asyncchecksuite*(name, body) =
  suite name:
    asyncmultisetup()

    teardown:
      checkTrackers()

    body

export helpers
