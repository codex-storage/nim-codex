import pkg/asynctest/chronos/unittest2

export unittest2 except eventually

template eventuallySafe*(
    expression: untyped, timeout = 5000, pollInterval = 1000
): bool =
  ## More sane defaults, for use with HTTP connections
  eventually(expression, timeout, pollInterval)

template eventually*(expression: untyped, timeout = 5000, pollInterval = 10): bool =
  ## Fast defaults, do not use with HTTP connections!
  eventually(expression, timeout, pollInterval)
