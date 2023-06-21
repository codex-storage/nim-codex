import pkg/chronos

type
  RepoKind* = enum
    repoFS = "fs"
    repoSQLite = "sqlite"

const
  MiB* = 1024 * 1024
  DefaultCacheSizeMiB* = 5
  DefaultCacheSize* = DefaultCacheSizeMiB * MiB
  DefaultBlockMaintenanceInterval* = 10.minutes
  DefaultNumberOfBlocksToMaintainPerInterval* = 1000
  DefaultMemoryStoreCapacityMiB* = 5
  DefaultMemoryStoreCapacity* = DefaultMemoryStoreCapacityMiB * MiB
  DefaultBlockTtl* = 24.hours
  DefaultQuotaBytes* = 1'u shl 33'u # ~8GB
