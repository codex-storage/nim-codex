## A LevelDB_ wrapper for Nim in a Nim friendly way.
##
## LevelDB is a fast and simple key/value data storage library built
## by Google that provides an ordered mapping from string keys to
## string values.
##
## .. _LevelDB: https://github.com/google/leveldb
##
## Create a database:
##
## .. code-block:: Nim
##    import leveldb
##    import options
##
##    var db = leveldb.open("/tmp/mydata")
##
## Read or modify the database content:
##
## .. code-block:: Nim
##
##    assert db.getOrDefault("nothing", "") == ""
##
##    db.put("hello", "world")
##    db.put("bin", "GIF89a\1\0")
##    echo db.get("hello")
##    assert db.get("hello").isSome()
##
##    var key, val = ""
##    for key, val in db.iter():
##      echo key, ": ", repr(val)
##
##    db.delete("hello")
##    assert db.get("hello").isNone()
##
## Batch writes:
##
## .. code-block:: Nim
##    let batch = newBatch()
##    for i in 1..10:
##      batch.put("key" & $i, $i)
##    batch.delete("bin")
##    db.write(batch)
##
## Iterate over subset of database content:
##
## .. code-block:: Nim
##    for key, val in db.iterPrefix(prefix = "key1"):
##      echo key, ": ", val
##    for key, val in db.iter(seek = "key3", reverse = true):
##      echo key, ": ", val
##
##    db.close()

import options, os, strutils
import leveldb/raw

type
  LevelDb* = ref object
    path*: string
    db: ptr leveldb_t
    cache: ptr leveldb_cache_t
    readOptions: ptr leveldb_readoptions_t
    syncWriteOptions: ptr leveldb_writeoptions_t
    asyncWriteOptions: ptr leveldb_writeoptions_t

  LevelDbWriteBatch* = ref object
    ## Write batches for bulk data modification.
    batch: ptr leveldb_writebatch_t

  CompressionType* = enum
    ## No compression or using Snappy_ algorithm (default).
    ##
    ## .. _Snappy: http://google.github.io/snappy/
    ctNoCompression = leveldb_no_compression,
    ctSnappyCompression = leveldb_snappy_compression

  LevelDbException* = object of CatchableError

const
  version* = block:
    const configFile = "leveldb.nimble"
    const sourcePath = currentSourcePath()
    const parentConfig = sourcePath.parentDir.parentDir / configFile
    const localConfig = sourcePath.parentDir / configFile
    var content: string
    if fileExists(parentConfig):
      content = staticRead(parentConfig)
    else:
      content = staticRead(localConfig)
    var version_line: string
    for line in content.split("\L"):
      if line.startsWith("version"):
        version_line = line
        break
    let raw = version_line.split("=", maxsplit = 1)[1]
    raw.strip().strip(chars = {'"'})

  levelDbTrue = uint8(1)
  levelDbFalse = uint8(0)

proc free(p: pointer) {.importc.}

proc checkError(errPtr: cstring) =
  if errPtr != nil:
    defer: free(errPtr)
    raise newException(LevelDbException, $errPtr)

proc getLibVersion*(): (int, int) =
  ## Get the version of leveldb C library.
  result[0] = leveldb_major_version()
  result[1] = leveldb_minor_version()

proc close*(self: LevelDb) =
  ## Closes the database.
  ##
  ## See also:
  ## * `open proc <#open%2Cstring%2Cint%2Cint%2Cint>`_
  if self.db == nil:
    return
  leveldb_close(self.db)
  leveldb_writeoptions_destroy(self.syncWriteOptions)
  leveldb_writeoptions_destroy(self.asyncWriteOptions)
  leveldb_readoptions_destroy(self.readOptions)
  if self.cache != nil:
    leveldb_cache_destroy(self.cache)
    self.cache = nil
  self.db = nil

proc open*(path: string, create = true, reuse = true, paranoidChecks = true,
    compressionType = ctSnappyCompression,
    cacheCapacity = 0, blockSize = 4 * 1024, writeBufferSize = 4*1024*1024,
    maxOpenFiles = 1000, maxFileSize = 2 * 1024 * 1024,
    blockRestartInterval = 16): LevelDb =
  ## Opens a database.
  ##
  ## Raises `LevelDbException` if corruption detected in the database.
  ##
  ## See also:
  ## * `close proc <#close%2CLevelDb>`_
  new(result, close)

  let options = leveldb_options_create()
  defer: leveldb_options_destroy(options)

  result.syncWriteOptions = leveldb_writeoptions_create()
  leveldb_writeoptions_set_sync(result.syncWriteOptions, levelDbTrue)
  result.asyncWriteOptions = leveldb_writeoptions_create()
  leveldb_writeoptions_set_sync(result.asyncWriteOptions, levelDbFalse)
  result.readOptions = leveldb_readoptions_create()

  if create:
    leveldb_options_set_create_if_missing(options, levelDbTrue)
  else:
    leveldb_options_set_create_if_missing(options, levelDbFalse)
  if reuse:
    leveldb_options_set_error_if_exists(options, levelDbFalse)
  else:
    leveldb_options_set_error_if_exists(options, levelDbTrue)
  if paranoidChecks:
    leveldb_options_set_paranoid_checks(options, levelDbTrue)
  else:
    leveldb_options_set_paranoid_checks(options, levelDbFalse)

  leveldb_options_set_write_buffer_size(options, writeBufferSize.csize_t)
  leveldb_options_set_block_size(options, blockSize.csize_t)
  leveldb_options_set_max_open_files(options, cast[cint](maxOpenFiles))
  leveldb_options_set_max_file_size(options, maxFileSize.csize_t)
  leveldb_options_set_block_restart_interval(options,
                                             cast[cint](blockRestartInterval))
  leveldb_options_set_compression(options, cast[cint](compressionType.ord))

  if cacheCapacity > 0:
    let cache = leveldb_cache_create_lru(cacheCapacity.csize_t)
    leveldb_options_set_cache(options, cache)
    result.cache = cache

  var errPtr: cstring = nil
  result.path = path
  result.db = leveldb_open(options, path, addr errPtr)
  checkError(errPtr)

proc put*(self: LevelDb, key: string, value: string, sync = false) =
  ## Set a `value` for the specified `key`.
  ##
  ## By default, `sync` is turned off, each write to leveldb is asynchronous.
  ## Unless reboot, a crash of just the writing process will not cause any
  ## loss since even when `sync` is false.
  ##
  ## See also:
  ## * `put proc <#put%2CLevelDbWriteBatch%2Cstring%2Cstring>`_
  runnableExamples:
    let db = leveldb.open("/tmp/test")
    db.put("hello", "world")
    db.close()

  assert self.db != nil
  var errPtr: cstring = nil
  let writeOptions = if sync: self.syncWriteOptions else: self.asyncWriteOptions
  leveldb_put(self.db, writeOptions,
              key, key.len.csize_t, value, value.len.csize_t, addr errPtr)
  checkError(errPtr)

proc newString(cstr: cstring, length: csize_t): string =
  if length > 0:
    result = newString(length)
    copyMem(unsafeAddr result[0], cstr, length)
  else:
    result = ""

proc get*(self: LevelDb, key: string): Option[string] =
  ## Get the value for the specified `key`.
  ##
  ## See also:
  ## * `getOrDefault proc <#getOrDefault%2CLevelDb%2Cstring>`_
  runnableExamples:
    let db = leveldb.open("/tmp/test")
    db.put("hello", "world")
    echo db.get("hello")
    db.close()

  var size: csize_t
  var errPtr: cstring = nil
  let s = leveldb_get(self.db, self.readOptions, key, key.len.csize_t, addr size, addr errPtr)
  checkError(errPtr)

  if s == nil:
    result = none(string)
  else:
    result = some(newString(s, size))
    free(s)

proc getOrDefault*(self: LevelDb, key: string, default = ""): string =
  ## Get the value for the specified `key`, or `default` if no value was set.
  ##
  ## See also:
  ## * `get proc <#get%2CLevelDb%2Cstring>`_
  runnableExamples:
    let db = leveldb.open("/tmp/test")
    doAssert db.getOrDefault("what?", "nothing") == "nothing"
    db.close()

  let val = self.get(key)
  if val.isNone():
    result = default
  else:
    result = val.get()

proc delete*(self: LevelDb, key: string, sync = false) =
  ## Delete the key/value pair for the specified key.
  ##
  ## See also:
  ## * `delete proc <#delete%2CLevelDbWriteBatch%2Cstring>`_
  var errPtr: cstring = nil
  let writeOptions = if sync: self.syncWriteOptions else: self.asyncWriteOptions
  leveldb_delete(self.db, writeOptions, key, key.len.csize_t, addr errPtr)
  checkError(errPtr)

proc destroy*(self: LevelDbWriteBatch) =
  ## Destroys this batch.
  ##
  ## See also:
  ## * `newBatch proc <#newBatch>`_
  if self.batch == nil:
    return
  leveldb_writebatch_destroy(self.batch)
  self.batch = nil

proc newBatch*(): LevelDbWriteBatch =
  ## Creates a new database write batch.
  ##
  ## See also:
  ## * `write proc <#write%2CLevelDb%2CLevelDbWriteBatch>`_
  ## * `put proc <#put%2CLevelDbWriteBatch%2Cstring%2Cstring>`_
  ## * `delete proc <#delete%2CLevelDbWriteBatch%2Cstring>`_
  ## * `append proc <#append%2CLevelDbWriteBatch%2CLevelDbWriteBatch>`_
  ## * `clear proc <#clear%2CLevelDbWriteBatch>`_
  ## * `destroy proc <#destroy%2CLevelDbWriteBatch>`_

  runnableExamples:
    let db = leveldb.open("/tmp/test")
    let batch = newBatch()
    for i in 1..10:
      batch.put("key" & $i, $i)
    batch.delete("another")
    db.write(batch)
    db.close()

  new(result, destroy)
  result.batch = leveldb_writebatch_create()

proc put*(self: LevelDbWriteBatch, key: string, value: string, sync = false) =
  ## Set a `value` for the specified `key`.
  ## Same as `put <#put%2CLevelDb%2Cstring%2Cstring>`_ but operates on the
  ## write batch instead.
  ##
  ## See also:
  ## * `put proc <#put%2CLevelDb%2Cstring%2Cstring>`_
  ## * `newBatch proc <#newBatch>`_
  leveldb_writebatch_put(self.batch, key, key.len.csize_t, value, value.len.csize_t)

proc append*(self, source: LevelDbWriteBatch) =
  ## Merges the `source` batch into this batch.
  ##
  ## See also:
  ## * `newBatch proc <#newBatch>`_
  leveldb_writebatch_append(self.batch, source.batch)

proc delete*(self: LevelDbWriteBatch, key: string) =
  ## Delete the key/value pair for the specified `key`.
  ## Same as `delete <#delete%2CLevelDb%2Cstring>`_ but operates on the
  ## write batch instead.
  ##
  ## See also:
  ## * `delete proc <#delete%2CLevelDb%2Cstring>`_
  ## * `newBatch proc <#newBatch>`_
  leveldb_writebatch_delete(self.batch, key, key.len.csize_t)

proc clear*(self: LevelDbWriteBatch) =
  ## Clear all updates buffered in this batch.
  ##
  ## See also:
  ## * `newBatch proc <#newBatch>`_
  leveldb_writebatch_clear(self.batch)

proc write*(self: LevelDb, batch: LevelDbWriteBatch) =
  ## Write apply the given `batch` to the database.
  ##
  ## See also:
  ## * `newBatch proc <#newBatch>`_
  var errPtr: cstring = nil
  leveldb_write(self.db, self.syncWriteOptions, batch.batch, addr errPtr)
  checkError(errPtr)

proc getIterData(iterPtr: ptr leveldb_iterator_t): (string, string) =
  var len: csize_t
  var str: cstring

  str = leveldb_iter_key(iterPtr, addr len)
  result[0] = newString(str, len)

  str = leveldb_iter_value(iterPtr, addr len)
  result[1] = newString(str, len)

iterator iter*(self: LevelDb, seek: string = "", reverse: bool = false): (
    string, string) =
  ## Iterate all key/value pairs in the database from the first one or
  ## the specified key `seek`.
  ## By default, the ordering will be lexicographic byte-wise ordering
  ## with leveldb builtin comparator, unless `reverse` set to `true`.
  ##
  ## See also:
  ## * `iterPrefix iterator <#iterPrefix.i%2CLevelDb%2Cstring>`_
  ## * `iterRange iterator <#iterRange.i%2CLevelDb%2Cstring%2Cstring>`_
  var iterPtr = leveldb_create_iterator(self.db, self.readOptions)
  defer: leveldb_iter_destroy(iterPtr)

  if seek.len > 0:
    leveldb_iter_seek(iterPtr, seek, seek.len.csize_t)
  else:
    if reverse:
      leveldb_iter_seek_to_last(iterPtr)
    else:
      leveldb_iter_seek_to_first(iterPtr)

  while true:
    if leveldb_iter_valid(iterPtr) == levelDbFalse:
      break

    var (key, value) = getIterData(iterPtr)
    var err: cstring = nil
    leveldb_iter_get_error(iterPtr, addr err)
    checkError(err)
    yield (key, value)

    if reverse:
      leveldb_iter_prev(iterPtr)
    else:
      leveldb_iter_next(iterPtr)

iterator iterPrefix*(self: LevelDb, prefix: string): (string, string) =
  ## Iterate subset key/value pairs in the database with a particular `prefix`.
  ##
  ## See also:
  ## * `iter iterator <#iter.i%2CLevelDb%2Cstring%2Cbool>`_
  ## * `iterRange iterator <#iterRange.i%2CLevelDb%2Cstring%2Cstring>`_
  for key, value in iter(self, prefix, reverse = false):
    if key.startsWith(prefix):
      yield (key, value)
    else:
      break

iterator iterRange*(self: LevelDb, start, limit: string): (string, string) =
  ## Yields all key/value pairs between the `start` and `limit` keys
  ## (inclusive) in the database.
  ##
  ## See also:
  ## * `iter iterator <#iter.i%2CLevelDb%2Cstring%2Cbool>`_
  ## * `iterPrefix iterator <#iterPrefix.i%2CLevelDb%2Cstring>`_
  let reverse: bool = limit < start
  for key, value in iter(self, start, reverse = reverse):
    if reverse:
      if key < limit:
        break
    else:
      if key > limit:
        break
    yield (key, value)

proc removeDb*(name: string) =
  ## Remove the database `name`.
  var err: cstring = nil
  let options = leveldb_options_create()
  leveldb_destroy_db(options, name, addr err)
  checkError(err)

proc repairDb*(name: string) =
  ## Repairs the corrupted database `name`.
  let options = leveldb_options_create()
  leveldb_options_set_create_if_missing(options, levelDbFalse)
  leveldb_options_set_error_if_exists(options, levelDbFalse)
  var errPtr: cstring = nil
  leveldb_repair_db(options, name, addr errPtr)
  checkError(errPtr)
