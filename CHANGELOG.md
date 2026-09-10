# Changelog

All notable changes to this project will be documented in this file.

## 2.0.0 - Unreleased

- Suballocate aligned buffer ranges from reusable, memory-type-specific
  `VkDeviceMemory` blocks using `generic_pool.RangeAllocator` while keeping
  images in isolated dedicated blocks.
- Add configurable preferred block size and maximum block count.
- Add allocator commitment and occupancy statistics.
- Add explicit empty-block trimming while retaining blocks for reuse by default.
- Validate allocation ownership before mapping, unmapping, or releasing ranges.
- Add deterministic CPU-only policy tests and a real Vulkan buffer smoke test.
