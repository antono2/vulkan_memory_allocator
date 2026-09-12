# Vulkan memory allocation helper for V

[Project portfolio](https://oreskin.de/projects_en.php)

This module provides small, explicit helpers for selecting Vulkan memory types,
allocating and binding memory for buffers and images, mapping host-visible
allocations, and suballocating shared `VkDeviceMemory` blocks.

Despite the repository name, this is not a binding to AMD's Vulkan Memory
Allocator. It is a compact V-native allocator intended to remain understandable
enough for examples while avoiding one Vulkan allocation per resource.

## How it fits together

The allocator has three deliberately separate layers:

1. **Policy** filters the memory types allowed by Vulkan, applies required
   property flags, and ranks the remaining types for GPU-only, upload, or
   readback use. The selected `MemoryTypeChoice` explains the heap, flags,
   budget state, and score.
2. **Block planning** uses `antono2.memory.RangeAllocator` to place compatible
   buffers into larger memory-type-specific blocks. This CPU-only layer is
   deterministic and independently tested.
3. **Vulkan ownership** creates, maps, binds, and frees `VkDeviceMemory` while
   `AllocationInfo` keeps the selected type, heap, properties, block size, and
   private ownership record together.

Images remain dedicated. That conservative rule avoids hiding the additional
tiling and buffer-image granularity rules that a safe image suballocator would
need to model. Existing `MemType` APIs remain available for short examples;
new applications should normally use `AllocationOptions`.

## Install
```sh
v install antono2.vkmemalloc
```

VPM installs the Vulkan bindings and `antono2.memory` dependencies automatically.

The Vulkan loader, headers, and a working GPU driver must also be installed.

For a fresh machine, install the native Vulkan prerequisites, V dependencies,
and run the compile checks with one command:

```sh
v run setup.vsh
```

Use `v run setup.vsh --check` for a read-only diagnostic pass.

The allocator uses the production-hardened v1.4 release of
[`antono2.memory`](https://github.com/antono2/memory), specifically
`memory.RangeAllocator`,
for its dependency-free block suballocation policy. Vulkan handles remain
isolated in this module.

## Basic use

Create one allocator after selecting a physical device and creating its logical
device:

```v
import antono2.vulkan as vk
import antono2.vkmemalloc as vma

mut allocator := vma.new(vma.AllocatorCreateInfo{
	physical_device: physical_device
	device: device
	preferred_block_size: 64 * 1024 * 1024
})
```

Buffer blocks are separated by Vulkan memory-type index. Small buffers share the
preferred block size; a buffer larger than that receives a large-enough block
of its own. Images use isolated dedicated blocks, avoiding buffer-image
granularity conflicts and satisfying Vulkan 1.1 dedicated-allocation metadata.
`max_memory_blocks` defaults to 256 and may be lowered in the create information.

The lower-level `allocate()` method also uses an isolated block because raw
`VkMemoryRequirements` do not identify whether the caller will bind a buffer or
image. Use `create_buffer()` when automatic buffer suballocation is desired.

## Policy-based allocation

The policy API expresses how the resource will be used and keeps hard
requirements distinct from preferences:

```v
options := vma.AllocationOptions{
	usage: .upload
	// These are optional refinements. Required flags are never dropped.
	preferred_flags: vk.MemoryPropertyFlags(vk.MemoryPropertyFlagBits.host_cached)
}
result := allocator.create_buffer_with_options(&buffer_info, options, &buffer,
	mut allocation)
```

- `.gpu_only` requires device-local memory.
- `.upload` requires host-visible memory and prefers coherent, device-local
  types.
- `.readback` requires host-visible memory and prefers cached, coherent types.
- `.automatic` has no implicit hard requirement and prefers device-local
  memory.

`required_flags` is a hard filter. `preferred_flags` improves a candidate's
rank, while `avoided_flags` lowers it without making the type unusable. The
default `.prefer_within` budget policy moves a heap with enough estimated room
ahead of an otherwise better match. `.require_within` filters over-budget
heaps for new Vulkan blocks while still permitting reuse of compatible blocks
that are already committed. `.ignore` ranks without considering room.

Use `allocator.select_memory_type(...)` when you need to inspect the choice
before creating a resource. Policy allocation tries compatible types in rank
order after reclaiming empty cached blocks on memory pressure. It never relaxes
required flags.

Allocate and bind a buffer, checking the returned Vulkan result:

```v
mut buffer := vk.Buffer(unsafe { nil })
mut allocation := vma.AllocationInfo{}
result := allocator.create_buffer(&buffer_info, .staging, &buffer, mut allocation)
if result != .success {
	return error('could not create buffer: ${result}')
}
```

For host-visible staging memory, map and unmap it as follows:

```v
mut mapped := voidptr(unsafe { nil })
if allocator.map(mut allocation, &mapped) != .success {
	return error('could not map buffer memory')
}
// Copy data to mapped here.
if allocator.flush(allocation) != .success {
	return error('could not flush buffer memory')
}
allocator.unmap(mut allocation)
```

For host-coherent memory, `flush()` and `invalidate()` are checked no-ops. For
non-coherent memory they call Vulkan with ranges expanded to
`nonCoherentAtomSize`. The `_range` variants accept allocation-relative offsets
and sizes. Flush after host writes before device access; invalidate only after
device writes have completed and before reading them on the host.

Destroy the Vulkan buffer or image before freeing its memory:

```v
vk.destroy_buffer(device, buffer, unsafe { nil })
if !allocator.release(mut allocation) {
	return error('allocation was not owned by this allocator')
}
```

`release()` returns shared-buffer ranges to their existing block so future
buffers can reuse them. Dedicated allocations are freed immediately. Empty
shared blocks remain cached; reclaim them explicitly when appropriate:

```v
println('released ${allocator.trim_empty_blocks()} empty memory blocks')
```

Call `allocator.destroy()` only after destroying every buffer and image backed
by it. This frees any allocations that were not individually released.

## Statistics

```v
stats := allocator.stats()
println('blocks: ${stats.block_count}')
println('allocations: ${stats.allocation_count}')
println('committed: ${stats.committed}, used: ${stats.used}, free: ${stats.free}')
println('largest free range: ${stats.largest_free_range}')
```

`committed` is memory obtained through `vkAllocateMemory`; `used` is the sum of
live resource ranges. `free_range_count`, `largest_free_range`, and
`empty_block_count` make cached capacity and external fragmentation visible.
The largest range is measured before applying the alignment of a future
request, so it is diagnostic rather than a guarantee that an allocation will
succeed.

Global free space can also belong to an incompatible Vulkan memory type. When
diagnosing a failed request, inspect the type selected for a comparable
allocation:

```v
type_stats := allocator.stats_for_memory_type(allocation.mem_type)
println('type ${allocation.mem_type}: free=${type_stats.free}, largest=${type_stats.largest_free_range}')
```

If total compatible free space is large enough but its largest range is too
small, the existing blocks are externally fragmented. If an empty block is
reported, `trim_empty_blocks()` can return it to Vulkan before retrying another
memory class. The allocator may still create a new compatible block when its
configured block limit and the Vulkan device allow it.

### Heap budgets

`VK_EXT_memory_budget` exposes driver estimates for current heap usage and the
amount the process can reasonably consume. The current integration uses Vulkan
1.1's properties query. Opt in only after confirming and enabling the device
extension:

```v
budget_supported := vma.supports_memory_budget(physical_device)
// Add vk.ext_memory_budget_extension_name to VkDeviceCreateInfo when true.
mut allocator := vma.new(vma.AllocatorCreateInfo{
	physical_device: physical_device
	device: device
	memory_budget_enabled: budget_supported
})

_ = allocator.refresh_memory_budget()
for heap in allocator.memory_heaps() {
	println('heap ${heap.heap_index}: ${heap.usage}/${heap.budget}')
}
```

The [runnable example](examples/buffer_suballocation/main.v) shows the complete
extension-name array and logical-device creation sequence.

`new()` obtains an initial enabled budget snapshot. Call
`refresh_memory_budget()` periodically (for example, once per frame or every
few seconds); policy selection uses the latest snapshot without adding a driver
query to every allocation. Without the extension, the same APIs fall back to
physical heap sizes and this allocator's own committed blocks. Budgets are
changing estimates, not reservations; Vulkan allocation can still fail and the
returned `vk.Result` remains authoritative.

## Persistent upload ring

`UploadRing` owns one dedicated, persistently mapped, host-coherent staging
buffer. Each allocation returns both a writable host pointer and the matching
buffer-relative offset for a transfer command:

```v
mut uploads := vma.new_upload_ring(mut allocator, 16 * 1024 * 1024) or {
	panic(err)
}
slice := uploads.allocate(4096, 256) or { panic(err) }

unsafe {
	copy(&u8(slice.data), source.data, source.len)
}
if uploads.flush(slice) != .success {
	return error('could not flush upload slice')
}
// Record a copy from uploads.buffer at slice.offset, submit it, and keep slice.

// After the protecting fence or timeline value has completed:
retired := uploads.retire(slice)
assert retired
```

Slices are strictly FIFO and never cross the end of the buffer. Retirement is
rejected when attempted out of order. The caller owns submission tracking and
must not retire a slice until the GPU has finished reading it. Call
`uploads.destroy()` before destroying the allocator or Vulkan device.
`uploads.stats()` returns `UploadRingStats`, keeping this module's public API
independent of the internal allocation-policy type.

`new_upload_ring()` deliberately requires host-coherent memory, so its
`flush()` calls are checked no-ops. Advanced callers can use
`new_upload_ring_with_options(..., AllocationOptions{ usage: .upload })` to
permit other host-visible types; flushing each written slice then handles
non-coherent memory correctly.

## Legacy memory classes

- `.staging` requires host-visible and host-coherent memory and may be mapped.
- `.gpu` requires device-local memory and normally cannot be mapped.
- `.first_available` selects the first memory type permitted by Vulkan's
  `memoryTypeBits`, regardless of its property flags.

## Ownership and limitations

- An `AllocationInfo` belongs to the allocator that created it.
- A successful `release()` clears the complete `AllocationInfo` and prevents a
  second free through that record.
- The allocator tracks at most 256 memory blocks by default. Each block can
  contain many suballocations.
- The allocator is not internally synchronized. Externally synchronize access
  when multiple threads can allocate or free concurrently.
- Concurrently mapped allocations in one shared block reuse a single underlying
  Vulkan mapping. Each successful `map()` must have a matching `unmap()`.
- The allocator does not relocate live resources or suballocate images.
- Heap budgets guide selection but cannot enforce a process-wide or system-wide
  limit because other allocators can change process usage and external system
  activity can change the budget concurrently.
- Vulkan objects must not outlive the memory bound to them.

All allocation and binding functions return `vk.Result`; callers should handle
errors instead of assuming allocation succeeds.

## Tests

The bookkeeping tests do not require a Vulkan-capable GPU:

```sh
v test .
```

The runnable example enables live budgets when available, creates two real
policy-selected upload buffers, verifies that they share a memory block, maps
and flushes them, creates a dedicated GPU-only image, prints heap diagnostics,
then exercises a persistently mapped upload ring through wraparound and FIFO
retirement:

```sh
v run examples/buffer_suballocation
```

CI executes this example against Mesa's CPU Vulkan implementation, so it does
not depend on access to a hardware GPU.
