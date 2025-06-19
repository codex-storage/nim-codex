import std/streams

import pkg/chronos
import pkg/libp2p/cid
import pkg/questionable/results

import ../node
import ../blocktype
import ../manifest
import ../stores/blockstore

import ./tarballs
import ./stdstreamwrapper
import ./directorymanifest
import ./encoding
import ./decoding

proc fetchDirectoryManifest*(
    self: CodexNodeRef, cid: Cid
): Future[?!DirectoryManifest] {.async: (raises: [CancelledError]).} =
  ## Fetch and decode a manifest block
  ##

  if err =? cid.isManifest.errorOption:
    return failure "CID has invalid content type for manifest {$cid}"

  trace "Retrieving directory manifest for cid", cid

  without blk =? await self.blockStore.getBlock(BlockAddress.init(cid)), err:
    trace "Error retrieving directory manifest block", cid, err = err.msg
    return failure err

  trace "Decoding directory manifest for cid", cid

  without manifest =? DirectoryManifest.decode(blk), err:
    trace "Unable to decode as directory manifest", err = err.msg
    return failure("Unable to decode as directory manifest")

  trace "Decoded directory manifest", cid

  manifest.success

proc storeDirectoryManifest*(
    self: CodexNodeRef, manifest: DirectoryManifest
): Future[?!Block] {.async.} =
  let encodedManifest = manifest.encode()

  without blk =? Block.new(data = encodedManifest, codec = ManifestCodec), error:
    trace "Unable to create block from manifest"
    return failure(error)

  if err =? (await self.blockStore.putBlock(blk)).errorOption:
    trace "Unable to store manifest block", cid = blk.cid, err = err.msg
    return failure(err)

  success blk

proc storeTarball*(
    self: CodexNodeRef, stream: AsyncStreamReader
): Future[?!string] {.async.} =
  info "Storing tarball data"

  # Just as a proof of concept, we process tar bar in memory
  # Later to see how to do actual streaming to either store
  # tarball locally in some tmp folder, or to process the
  # tarball incrementally 
  let tarballBytes = await stream.read()
  let stream = newStringStream(string.fromBytes(tarballBytes))

  proc onProcessedTarFile(
      stream: Stream, fileName: string
  ): Future[?!Cid] {.gcsafe, async: (raises: [CancelledError]).} =
    try:
      echo "onProcessedTarFile:name: ", fileName
      let stream = newStdStreamWrapper(stream)
      await self.store(stream, filename = some fileName, pad = false)
    except CancelledError as e:
      raise e
    except CatchableError as e:
      error "Error processing tar file", fileName, exc = e.msg
      return failure(e.msg)

  proc onProcessedTarDir(
      name: string, cids: seq[Cid]
  ): Future[?!Cid] {.gcsafe, async: (raises: [CancelledError]).} =
    try:
      echo "onProcessedTarDir:name: ", name
      echo "onProcessedTarDir:cids: ", cids
      let directoryManifest = newDirectoryManifest(name = name, cids = cids)
      without manifestBlk =? await self.storeDirectoryManifest(directoryManifest), err:
        error "Unable to store manifest"
        return failure(err)
      manifestBlk.cid.success
    except CancelledError as e:
      raise e
    except CatchableError as e:
      error "Error processing tar dir", name, exc = e.msg
      return failure(e.msg)

  let tarball = Tarball()
  if err =? (await tarball.open(stream, onProcessedTarFile)).errorOption:
    error "Unable to open tarball", err = err.msg
    return failure(err)
  echo "tarball = ", $tarball
  without root =? tarball.findRootDir(), err:
    return failure(err.msg)
  echo "root = ", root
  let dirs = processDirEntries(tarball)
  echo "dirs = ", dirs
  without tree =? (await buildTree(root = root, dirs = dirs, onProcessedTarDir)), err:
    error "Unable to build tree", err = err.msg
    return failure(err)
  echo ""
  echo "preorderTraversal:"
  let json = newJArray()
  preorderTraversal(tree, json)
  echo "json = ", json
  success($json)
