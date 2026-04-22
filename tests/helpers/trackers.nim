import pkg/storage/streams/storestream
import pkg/unittest2

const trackerNames = [StoreStreamTrackerName]

proc checkTrackers*() =
  for name in trackerNames:
    let counter = getTrackerCounter(name)
    if counter.opened != counter.closed:
      # show how many streams were opened vs closed to help diagnose the leak
      checkpoint name & ": opened=" & $counter.opened & ", closed=" & $counter.closed
      fail()
  GC_fullCollect()
