import ./utils/asyncheapqueue
import ./utils/fileutils

export asyncheapqueue, fileutils


func divUp*[T](a, b : T): T =
  ## Division with result rounded up (rather than truncated as in 'div')
  assert(b != 0)
  if a==0:  0  else:  ((a - 1) div b) + 1

func roundUp*[T](a, b : T): T =
  ## Round up 'a' to the next value divisible by 'b'
  divUp(a,b) * b

