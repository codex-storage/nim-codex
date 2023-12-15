import pkg/questionable
import pkg/questionable/results

proc someFn*(
  X: type int
): ?!int =
  let res = success(1)

  if err =? res.errorOption:
    echo "err" & err.msg
  else:
    echo "no err"

  failure("")
