import std/hashes
import pkg/nimcrypto

type PurchaseId* = distinct array[32, byte]

proc hash*(x: PurchaseId): Hash {.borrow.}
proc `==`*(x, y: PurchaseId): bool {.borrow.}
proc toHex*(x: PurchaseId): string = array[32, byte](x).toHex
