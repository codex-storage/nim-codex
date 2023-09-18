import pkg/chronos
import pkg/upraises

type
  GetNext*[T] = proc(): Future[T] {.upraises: [], gcsafe, closure.}
  Iter*[T] = ref object
    finished*: bool
    next*: GetNext[T]