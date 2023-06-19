import pkg/stint

func fromString*(T: typedesc[StUint|StInt], s: string): T {.inline.} =
  parse(s, type result, radix = 10)
