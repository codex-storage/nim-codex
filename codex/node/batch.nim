import pkg/chronos
import pkg/upraises
import ../blocktype as bt

type
  BatchProc* = proc(blocks: seq[bt.Block]): Future[void] {.gcsafe, upraises:[].}
