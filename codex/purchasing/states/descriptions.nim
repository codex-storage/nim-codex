import ../statemachine
import ./cancelled
import ./error
import ./failed
import ./finished
import ./pending
import ./started
import ./submitted

proc description*(state: PurchaseState): string =
  if state of PurchaseCancelled:
    "cancelled"
  elif state of PurchaseErrored:
    "errored"
  elif state of PurchaseFailed:
    "failed"
  elif state of PurchaseFinished:
    "finished"
  elif state of PurchasePending:
    "pending"
  elif state of PurchaseStarted:
    "started"
  elif state of PurchaseSubmitted:
    "submitted"
  else:
    "unknown"

