import std/sequtils

proc createDoubleArray*(
    outerLen, innerLen: int
): ptr UncheckedArray[ptr UncheckedArray[byte]] =
  # Allocate outer array
  result = cast[ptr UncheckedArray[ptr UncheckedArray[byte]]](allocShared0(
    sizeof(ptr UncheckedArray[byte]) * outerLen
  ))

  # Allocate each inner array
  for i in 0 ..< outerLen:
    result[i] = cast[ptr UncheckedArray[byte]](allocShared0(sizeof(byte) * innerLen))

proc freeDoubleArray*(
    arr: ptr UncheckedArray[ptr UncheckedArray[byte]], outerLen: int
) =
  # Free each inner array
  for i in 0 ..< outerLen:
    if not arr[i].isNil:
      deallocShared(arr[i])

  # Free outer array
  if not arr.isNil:
    deallocShared(arr)
