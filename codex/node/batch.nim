import pkg/chronos
import ../asyncyeah
import pkg/upraises
import ../blocktype as bt

type
  BatchProc* = proc(blocks: seq[bt.Block]): Future[void] {.gcsafe, upraises:[].}
