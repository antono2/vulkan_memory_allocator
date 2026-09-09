
# Vulkan memory allocation helper for V

[Project portfolio](https://oreskin.de/projects_en.php)

This module provides small, explicit helpers for selecting Vulkan memory types,
allocating and binding memory for buffers and images, mapping host-visible
allocations, and releasing owned `VkDeviceMemory` handles.

Despite the repository name, this is not a binding to AMD's Vulkan Memory
Allocator and it is not a suballocator. Each successful request creates one
dedicated Vulkan memory allocation. It is suitable for examples and
applications with a modest number of long-lived resources.

## Install
```sh
v install https://github.com/antono2/vulkan
v install antono2.vkmemalloc
```

The Vulkan loader, headers, and a working GPU driver must also be installed.

## Basic use

Create one allocator after selecting a physical device and creating its logical
device:

```v
import vulkan as vk
import antono2.vkmemalloc as vma

mut allocator := vma.new(vma.AllocatorCreateInfo{
	physical_device: physical_device
	device: device
})
```

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

Call `allocator.destroy()` only after destroying every buffer and image backed
by it. This frees any allocations that were not individually released.

## Memory classes

- `.staging` requires host-visible and host-coherent memory and may be mapped.
- `.gpu` requires device-local memory and normally cannot be mapped.
- `.first_available` selects the first memory type permitted by Vulkan's
  `memoryTypeBits`, regardless of its property flags.

## Ownership and limitations

- An `AllocationInfo` belongs to the allocator that created it.
- A successful `release()` clears the complete `AllocationInfo` and prevents a
  second free through that record.
- The allocator tracks at most 256 simultaneous allocations. Released slots
  are reused.
- The allocator is not internally synchronized. Externally synchronize access
  when multiple threads can allocate or free concurrently.
- It does not suballocate, defragment, budget memory, choose between equivalent
  heaps, or automatically flush non-coherent memory.
- Vulkan objects must not outlive the memory bound to them.

All allocation and binding functions return `vk.Result`; callers should handle
errors instead of assuming allocation succeeds.

## Tests

The bookkeeping tests do not require a Vulkan-capable GPU:

```sh
v test .
```
