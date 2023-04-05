import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/asynctest
import pkg/datastore
import pkg/json_serialization
import pkg/json_serialization/std/options
import pkg/stew/byteutils

import pkg/codex/stores
import pkg/codex/sales

import ../examples
import ./helpers

suite "Reservations module":

  var
    repo: RepoStore
    repoDs: Datastore
    metaDs: SQLiteDatastore
    availability: Availability
    reservations: Reservations

  setup:
    repoDs = SQLiteDatastore.new(Memory).tryGet()
    metaDs = SQLiteDatastore.new(Memory).tryGet()
    repo = RepoStore.new(repoDs, metaDs)
    reservations = Reservations.new(repo)
    availability = Availability.example

  test "availability can be serialised and deserialised":
    let availability = Availability.example
    let serialised = availability.toJson
    check Json.decode(serialised, Availability) == availability

  test "has no availability initially":
    check (await reservations.allAvailabilities()).len == 0

  test "generates unique ids for storage availability":
    let availability1 = Availability.init(1.u256, 2.u256, 3.u256, 4.u256)
    let availability2 = Availability.init(1.u256, 2.u256, 3.u256, 4.u256)
    check availability1.id != availability2.id

  test "can reserve available storage":
    let availability1 = Availability.example
    let availability2 = Availability.example
    check isOk await reservations.reserve(availability1)
    check isOk await reservations.reserve(availability2)

    let availabilities = await reservations.allAvailabilities()
    check:
      # perform unordered checks
      availabilities.len == 2
      availabilities.contains(availability1)
      availabilities.contains(availability2)

  test "reserved availability exists":
    check isOk await reservations.reserve(availability)

    without exists =? await reservations.exists(availability.id):
      fail()

    check exists

  test "reserved availability can be partially released":
    let size = availability.size.truncate(uint)
    check isOk await reservations.reserve(availability)
    check isOk await reservations.release(availability.id, size - 1)

    without a =? await reservations.get(availability.id):
      fail()

    check a.size == 1

  test "availability is deleted after being fully released":
    let size = availability.size.truncate(uint)
    check isOk await reservations.reserve(availability)
    check isOk await reservations.release(availability.id, size)

    without exists =? await reservations.exists(availability.id):
      fail()

    check not exists

  test "non-existant availability cannot be released":
    let size = availability.size.truncate(uint)
    let r = await reservations.release(availability.id, size - 1)
    check r.error of AvailabilityGetFailedError
    check r.error.msg == "Availability does not exist"

  test "added availability is not used initially":
    check isOk await reservations.reserve(availability)

    without available =? await reservations.get(availability.id):
      fail()

    check not available.used

  test "availability can be marked used":
    check isOk await reservations.reserve(availability)

    check isOk await reservations.markUsed(availability.id)

    without available =? await reservations.get(availability.id):
      fail()

    check available.used

  test "availability can be marked unused":
    check isOk await reservations.reserve(availability)

    check isOk await reservations.markUsed(availability.id)
    check isOk await reservations.markUnused(availability.id)

    without available =? await reservations.get(availability.id):
      fail()

    check not available.used

  test "used availability can be found":
    check isOk await reservations.reserve(availability)

    check isOk await reservations.markUsed(availability.id)

    without available =? await reservations.find(availability.size,
      availability.duration, availability.minPrice, availability.maxCollateral, used = true):

      fail()

  test "unused availability can be found":
    check isOk await reservations.reserve(availability)

    without available =? await reservations.find(availability.size,
      availability.duration, availability.minPrice, availability.maxCollateral, used = false):

      fail()

  test "non-existant availability cannot be found":
    check isNone (await reservations.find(availability.size,
      availability.duration, availability.minPrice, availability.maxCollateral, used = false))

  test "non-existant availability cannot be retrieved":
    let r = await reservations.get(availability.id)
    check r.error of AvailabilityGetFailedError
    check r.error.msg == "Availability does not exist"

  test "same availability cannot be reserved twice":
    check isOk await reservations.reserve(availability)
    let r = await reservations.reserve(availability)
    check r.error of AvailabilityAlreadyExistsError

  test "can get available bytes in repo":
    check reservations.available == DefaultQuotaBytes

  test "reserving availability reduces available bytes":
    check isOk await reservations.reserve(availability)
    check reservations.available ==
      DefaultQuotaBytes - availability.size.truncate(uint)

  test "reports quota available to be reserved":
    check reservations.hasAvailable(availability.size.truncate(uint))

  test "reports quota not available to be reserved":
    repo = RepoStore.new(repoDs, metaDs,
                         quotaMaxBytes = availability.size.truncate(uint) - 1)
    reservations = Reservations.new(repo)
    check not reservations.hasAvailable(availability.size.truncate(uint))

  test "fails to reserve availability with size that is larger than available quota":
    repo = RepoStore.new(repoDs, metaDs,
                         quotaMaxBytes = availability.size.truncate(uint) - 1)
    reservations = Reservations.new(repo)
    let r = await reservations.reserve(availability)
    check r.error of AvailabilityReserveFailedError
    check r.error.parent of QuotaNotEnoughError
    check exists =? (await reservations.exists(availability.id)) and not exists

  test "fails to release availability size that is larger than available quota":
    let size = availability.size.truncate(uint)
    repo = RepoStore.new(repoDs, metaDs,
                         quotaMaxBytes = size)
    reservations = Reservations.new(repo)
    discard await reservations.reserve(availability)
    let r = await reservations.release(availability.id, size + 1)
    check r.error of AvailabilityReleaseFailedError
    check r.error.parent.msg == "Cannot release this many bytes"
