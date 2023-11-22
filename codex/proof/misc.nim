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
