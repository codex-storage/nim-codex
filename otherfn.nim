
import pkg/questionable
import pkg/questionable/results

import ./somefn

proc otherFn*(): void =

  without x =? int.someFn(), err:
    echo "was err" & err.msg
