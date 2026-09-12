# Changelog

All notable changes to this project will be documented in this file.

## 2.5.0 - 2026-09-12

- Add cumulative allocation, fallback, block-reuse, trim, and high-water-mark
  counters alongside current allocator statistics.
- Add an opt-in bounded lifecycle event trace with deterministic sequence
  numbers, chronological snapshots, overwrite accounting, and resettable
  measurement windows.
- Add a 30,000-operation deterministic block-planner workload that continuously
  verifies ownership, overlap, accounting, memory-type isolation, and complete
  coalescing.
- Extend the lavapipe integration example with 1,536 real Vulkan buffer
  allocations, mapped writes, flushes, fragmented reuse, and trace validation.
- Keep tracing disabled by default and retain the allocator's existing external
  synchronization contract.

## 2.4.0 - 2026-09-12

- Add explainable, deterministic memory-type ranking for GPU-only, upload,
  readback, and automatic usage, with required, preferred, and avoided flags.
- Add optional `VK_EXT_memory_budget` discovery, refresh, selection policy, and
  per-heap diagnostics with a portable allocator-commitment fallback.
- Add policy-based raw, buffer, dedicated-buffer, and image allocation APIs
  while preserving the existing `MemType` entry points.
- Retry allocation after trimming empty blocks and fall through to compatible
  lower-ranked memory types on host/device out-of-memory results.
- Record the selected heap, property flags, and containing block size in every
  allocation.
- Add checked `flush`, `flush_range`, `invalidate`, and `invalidate_range`
  helpers aligned to the device's `nonCoherentAtomSize`.
- Add policy-selected upload rings and slice-level flush/invalidate helpers
  while retaining the coherent default constructor.
- Document the allocator from a high-level policy/planning/ownership viewpoint
  and exercise policy selection, live budgets, and flushing with lavapipe.

## 2.3.2 - 2026-09-12

- Promote the allocation-policy dependency to the production-hardened
  `antono2.memory` v1.4.0 release.
- Validate the pinned memory release in CPU allocator tests and the real
  lavapipe Vulkan suballocation smoke test.

## 2.3.1 - 2026-09-11

- Expose global and per-memory-type free-range, largest-contiguous-range, and
  empty-block diagnostics without changing allocation policy.

## 2.3.0 - 2026-09-11

- Migrate the allocation-policy dependency to the canonical `antono2.memory`
  module and pin it to the immutable v1.1.0 release.

## 2.2.0 - 2026-09-10

- Pin the allocation-policy dependency to the immutable v1.0.3 short-name
  release, superseded by the canonical dependency in v2.3.0.
- Return a local `UploadRingStats` value from `UploadRing.stats()` so the public
  Vulkan API does not expose the underlying policy module's type.
- Share one reference-counted Vulkan mapping across mapped suballocations in the
  same block, allowing production consumers to keep multiple staging ranges
  mapped concurrently.

## 2.1.1 - 2026-09-10

- Pin the general allocation dependency to `memory` v0.2.0 so released
  `generic_pool` imports remain reproducible when the module is renamed.

## 2.1.0 - 2026-09-10

- Free dedicated allocation blocks immediately on release while retaining
  reusable shared buffer blocks.
- Add `UploadRing`, a dedicated persistently mapped staging buffer with aligned
  FIFO allocation, checked retirement, wraparound, and occupancy statistics.

## 2.0.0 - 2026-09-10

- Suballocate aligned buffer ranges from reusable, memory-type-specific
  `VkDeviceMemory` blocks using `generic_pool.RangeAllocator` while keeping
  images in isolated dedicated blocks.
- Add configurable preferred block size and maximum block count.
- Add allocator commitment and occupancy statistics.
- Add explicit empty-block trimming while retaining blocks for reuse by default.
- Validate allocation ownership before mapping, unmapping, or releasing ranges.
- Add deterministic CPU-only policy tests and a real Vulkan buffer smoke test.
