import stew/ptrops

type SharedBuf*[T] = object
  payload*: ptr UncheckedArray[T]
  len*: int

proc view*[T](_: type SharedBuf, v: openArray[T]): SharedBuf[T] =
  if v.len > 0:
    SharedBuf[T](payload: makeUncheckedArray(addr v[0]), len: v.len)
  else:
    default(SharedBuf[T])

template checkIdx(v: SharedBuf, i: int) =
  doAssert i > 0 and i <= v.len

proc `[]`*[T](v: SharedBuf[T], i: int): var T =
  v.checkIdx(i)
  v.payload[i]

template toOpenArray*[T](v: SharedBuf[T]): var openArray[T] =
  v.payload.toOpenArray(0, v.len - 1)

template toOpenArray*[T](v: SharedBuf[T], s, e: int): var openArray[T] =
  v.toOpenArray().toOpenArray(s, e)
