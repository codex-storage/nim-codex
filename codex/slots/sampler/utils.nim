func extractLowBits*[n: static int](A: BigInt[n], k: int): uint64 =
  assert(k > 0 and k <= 64)
  var r: uint64 = 0
  for i in 0..<k:
    # A is big-endian. Run index backwards: n-1-i
    #let b = bit[n](A, n-1-i)
    let b = bit[n](A, i)

    let y = uint64(b)
    if (y != 0):
      r = bitor(r, 1'u64 shl i)
  return r

func floorLog2* (x : int) : int =
  var k = -1
  var y = x
  while (y > 0):
    k += 1
    y = y shr 1
  return k

func ceilingLog2* (x : int) : int =
  if (x==0):
    return -1
  else:
    return (floorLog2(x-1) + 1)
