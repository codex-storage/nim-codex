import ./helpers

## Unit testing suite that calls checkTrackers in teardown to check for memory leaks using chronos trackers.
template checksuite*(name, body) =
  suite name:
    multisetup()

    teardown:
      checkTrackers()

    body

template asyncchecksuite*(name, body) =
  suite name:
    asyncmultisetup()

    teardown:
      checkTrackers()

    body

export helpers
