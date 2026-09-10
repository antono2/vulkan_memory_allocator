# Vulkan memory allocation helper for V

[Project portfolio](https://oreskin.de/projects_en.php)

This module provides small, explicit helpers for selecting Vulkan memory types,
allocating and binding memory for buffers and images, mapping host-visible
allocations, and suballocating shared `VkDeviceMemory` blocks.

Despite the repository name, this is not a binding to AMD's Vulkan Memory
Allocator. It is a compact V-native allocator intended to remain understandable
enough for examples while avoiding one Vulkan allocation per resource.

## Install
```sh
v install antono2.vkmemalloc
```

VPM installs the Vulkan bindings and `antono2.mem` dependencies automatically.

The Vulkan loader, headers, and a working GPU driver must also be installed.

The allocator uses [`antono2.mem`](https://github.com/antono2/mem),
specifically `mem.RangeAllocator`,
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
allocator.unmap(mut allocation)
```

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
```

`committed` is memory obtained through `vkAllocateMemory`; `used` is the sum of
live resource ranges. Free bytes may be fragmented across blocks.

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

## Memory classes

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
- The allocator does not relocate live resources, enforce heap budgets, choose
  between equivalent heaps, or automatically flush non-coherent memory.
- Vulkan objects must not outlive the memory bound to them.

All allocation and binding functions return `vk.Result`; callers should handle
errors instead of assuming allocation succeeds.

## Tests

The bookkeeping tests do not require a Vulkan-capable GPU:

```sh
v test .
```

The runnable example creates two real buffers, verifies that they share a
memory block, maps one range, creates a dedicated image, then exercises a
persistently mapped upload ring through wraparound and FIFO retirement:

```sh
v run examples/buffer_suballocation
```

CI executes this example against Mesa's CPU Vulkan implementation, so it does
not depend on access to a hardware GPU.
