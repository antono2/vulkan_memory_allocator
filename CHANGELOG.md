# Changelog

All notable changes to this project will be documented in this file.

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
