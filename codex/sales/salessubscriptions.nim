import pkg/chronos
import ../market

type
  SalesSubscriptions* = ref object
    failed*: ?Subscription
    fulfilled*: ?Subscription
    slotFilled*: ?Subscription
    slotFreed*: ?Subscription
    requested*: ?Subscription
    cancelled*: ?Subscription

proc new*(_: type SalesSubscriptions): SalesSubscriptions =
  SalesSubscriptions(
    failed: none Subscription,
    fulfilled: none Subscription,
    slotFilled: none Subscription,
    slotFreed: none Subscription,
    requested: none Subscription,
    cancelled: none Subscription,
  )
