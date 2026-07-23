## Logos Storage
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/storage/discovery
import pkg/contractabi/address as ca

type MockDiscovery* = ref object of Discovery
  findBlockProvidersHandler*: proc(
    d: MockDiscovery, cid: Cid
  ): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).}

  publishBlockProvideHandler*:
    proc(d: MockDiscovery, cid: Cid): Future[void] {.async: (raises: [CancelledError]).}

  findHostProvidersHandler*: proc(
    d: MockDiscovery, host: ca.Address
  ): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).}

  publishHostProvideHandler*: proc(d: MockDiscovery, host: ca.Address): Future[void] {.
    async: (raises: [CancelledError])
  .}

proc new*(T: type MockDiscovery): MockDiscovery =
  MockDiscovery()

proc findPeer*(
    d: Discovery, peerId: PeerId
): Future[?PeerRecord] {.async: (raises: [CancelledError]).} =
  ## mock find a peer - always return none
  ##
  return none(PeerRecord)

method find*(
    d: MockDiscovery, cid: Cid
): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
  if isNil(d.findBlockProvidersHandler):
    return

  return await d.findBlockProvidersHandler(d, cid)

method provide*(
    d: MockDiscovery, cid: Cid
): Future[void] {.async: (raises: [CancelledError]).} =
  if isNil(d.publishBlockProvideHandler):
    return

  await d.publishBlockProvideHandler(d, cid)

method find*(
    d: MockDiscovery, host: ca.Address
): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
  if isNil(d.findHostProvidersHandler):
    return

  return await d.findHostProvidersHandler(d, host)

method provide*(
    d: MockDiscovery, host: ca.Address
): Future[void] {.async: (raises: [CancelledError]).} =
  if isNil(d.publishHostProvideHandler):
    return

  await d.publishHostProvideHandler(d, host)

proc nullDiscovery*(): MockDiscovery =
  proc findBlockProvidersHandler(
      d: MockDiscovery, cid: Cid
  ): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
    return @[]

  proc publishBlockProvideHandler(
      d: MockDiscovery, cid: Cid
  ): Future[void] {.async: (raises: [CancelledError]).} =
    return

  proc findHostProvidersHandler(
      d: MockDiscovery, host: ca.Address
  ): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
    return @[]

  proc publishHostProvideHandler(
      d: MockDiscovery, host: ca.Address
  ): Future[void] {.async: (raises: [CancelledError]).} =
    return

  return MockDiscovery(
    findBlockProvidersHandler: findBlockProvidersHandler,
    publishBlockProvideHandler: publishBlockProvideHandler,
    findHostProvidersHandler: findHostProvidersHandler,
    publishHostProvideHandler: publishHostProvideHandler,
  )

# Slightly more contrived Discovery mock to allow testing of the privacy toggle.
# Since we cannot declare `method` within blocks, we have to do this contortionism
# here.
type MixMockDiscovery* = ref object of Discovery
  privateSpr*: SignedPeerRecord
  directSpr*: SignedPeerRecord
  refCid*: Cid

method findViaMix*(
    d: MixMockDiscovery, cid: Cid
): Future[?!seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
  doAssert cid == d.refCid
  result = success(@[d.privateSpr])

method findDirect*(
    d: MixMockDiscovery, cid: Cid
): Future[?!seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
  doAssert cid == d.refCid
  result = success(@[d.directSpr])
