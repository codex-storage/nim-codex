import pkg/upraises

push: {.upraises: [].}

import std/sugar

import pkg/chronos
import pkg/chronos/futures
import pkg/datastore
import pkg/questionable
import pkg/questionable/results
import pkg/stew/results

import ../utils
import ../utils/genericcoders

type
  ModifyT*[T] = proc(v: ?T): Future[?T] {.upraises: [CatchableError], gcsafe, closure.}
  ModifyTGetU*[T, U] = proc(v: ?T): Future[(?T, U)] {.upraises: [CatchableError], gcsafe, closure.}

  BytesTuple = (?seq[byte], seq[byte])

  KeyVal[T] = (?Key, ?!T)
  ResIter[T] =  Future[KeyVal[T]]


proc putT*[T](self: Datastore, key: Key, t: T): Future[?!void] {.async.} =
  await self.put(key, t.encode)

proc getT*[T](self: Datastore, key: Key): Future[?!T] {.async.} =
  without bytes =? await self.get(key), errx:
    return failure(errx)

  T.decode(bytes)

proc queryT*[T](self: Datastore, query: Query): Future[?!Iter[Future[KeyVal[T]]]] {.async.} =
  without queryIter =? (await self.query(query)), errx:
    trace "Unable to execute block expirations query"
    return failure(errx)

  if queryIter.finished:
    trace "Disposing iterator"
    let res = await queryIter.dispose()
    if res.isErr:
      return failure(res.error)
    return success(emptyIter[ResIter[T]]())

  proc genNext: Future[KeyVal[T]] {.async.} =
    without pair =? await queryIter.next(), errx:
      trace "Disposing iterator"
      let res = await queryIter.dispose()
      if res.isErr:
        raise res.error
      raise errx

    if queryIter.finished:
      trace "Disposing iterator"
      let res = await queryIter.dispose()
      if res.isErr:
        raise res.error

    return (pair.key, T.decode(pair.data))

  proc isFinished(): bool = queryIter.finished

  Iter.new(genNext, isFinished).success

proc modifyT*[T](self: Datastore, key: Key, fn: ModifyT[T]): Future[?!void] {.async.} =
  proc wrappedFn(maybeBytes: ?seq[byte]): Future[?seq[byte]] {.async.} =
    var
      maybeNextT: ?T
    if bytes =? maybeBytes:
      without t =? T.decode(bytes), errx:
        raise errx

      maybeNextT = await fn(t.some)
    else:
      maybeNextT = await fn(T.none)

    if nextT =? maybeNextT:
      return nextT.encode().some
    else:
      return seq[byte].none

  await self.modify(key, wrappedFn)

proc modifyTGetU*[T, U](self: Datastore, key: Key, fn: ModifyTGetU[T, U]): Future[?!U] {.async.} =
  proc wrappedFn(maybeBytes: ?seq[byte]): Future[BytesTuple] {.async.} =
    var
      maybeNextT: ?T
      aux: U
    if bytes =? maybeBytes:
      without t =? T.decode(bytes), errx:
        raise errx

      (maybeNextT, aux) = await fn(t.some)
    else:
      (maybeNextT, aux) = await fn(T.none)

    if nextT =? maybeNextT:
      let b: seq[byte] = nextT.encode()
      return (b.some, aux.encode())
    else:
      return (seq[byte].none, aux.encode())

  without auxBytes =? await self.modifyGet(key, wrappedFn), errx:
    return failure(errx)

  U.decode(auxBytes)
