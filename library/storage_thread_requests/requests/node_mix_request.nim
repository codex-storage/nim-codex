import chronos
import chronicles
import results

import ../../../storage/[storage, node]

logScope:
  topics = "libstorage libstoragemix"

type NodeMixRequest* = object
  privateQueries: bool

proc createShared*(T: type NodeMixRequest, privateQueries: bool): ptr type T =
  var ret = createShared(T)
  ret[].privateQueries = privateQueries
  return ret

proc destroyShared*(self: ptr NodeMixRequest) =
  deallocShared(self)

proc process*(
    self: ptr NodeMixRequest, storage: ptr StorageServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  let previous = storage[].node.togglePrivateQueries(self.privateQueries).valueOr:
    return err(error.msg)
  return ok($previous)
