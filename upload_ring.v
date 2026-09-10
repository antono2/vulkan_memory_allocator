module vkmemalloc

import generic_pool
import antono2.vulkan as vk

// UploadSlice identifies one persistently mapped staging-buffer range. Slices
// must be retired in allocation order after the GPU no longer reads them.
pub struct UploadSlice {
	owner      voidptr
	allocation generic_pool.RingAllocation
pub:
	offset u64
	size   u64
	data   voidptr
}

// UploadRing owns one dedicated, persistently mapped Vulkan staging buffer and
// suballocates it with FIFO ring semantics. It is not internally synchronized.
pub struct UploadRing {
pub:
	buffer   vk.Buffer
	capacity u64
mut:
	allocator &Allocator = unsafe { nil }
	backing   AllocationInfo
	mapped    voidptr                     = unsafe { nil }
	ranges    &generic_pool.RingAllocator = unsafe { nil }
	destroyed bool
}

// new_upload_ring creates and persistently maps a coherent transfer-source
// buffer. The allocator must outlive the returned upload ring.
pub fn new_upload_ring(mut allocator Allocator, capacity u64) !&UploadRing {
	if capacity == 0 {
		return error('upload ring capacity must be greater than zero')
	}
	$if x32 {
		if capacity > u64(max_u32) {
			return error('upload ring capacity exceeds the host address space')
		}
	}
	buffer_info := vk.BufferCreateInfo{
		size:        capacity
		usage:       u32(vk.BufferUsageFlagBits.transfer_src)
		sharingMode: .exclusive
	}
	mut buffer := vk.Buffer(unsafe { nil })
	mut backing := AllocationInfo{}
	result := allocator.create_dedicated_buffer(&buffer_info, .staging, &buffer, mut backing)
	if result != .success {
		return error('could not create upload buffer: ${result}')
	}
	mut mapped := voidptr(unsafe { nil })
	map_result := allocator.map(mut backing, &mapped)
	if map_result != .success {
		vk.destroy_buffer(allocator.create_info.device, buffer, unsafe { nil })
		_ = allocator.release(mut backing)
		return error('could not map upload buffer: ${map_result}')
	}
	return &UploadRing{
		buffer:    buffer
		capacity:  capacity
		allocator: allocator
		backing:   backing
		mapped:    mapped
		ranges:    generic_pool.new_ring_allocator(capacity)
	}
}

// allocate reserves an aligned upload range and returns its host pointer and
// buffer-relative offset. A payload never crosses the end of the buffer.
pub fn (mut ring UploadRing) allocate(size u64, alignment u64) !UploadSlice {
	if ring.destroyed || isnil(ring.mapped) {
		return error('upload ring is destroyed')
	}
	allocation := ring.ranges.allocate(size, alignment)!
	data := unsafe { voidptr(usize(ring.mapped) + usize(allocation.offset)) }
	return UploadSlice{
		owner:      ring
		allocation: allocation
		offset:     allocation.offset
		size:       allocation.size
		data:       data
	}
}

// contains reports whether a slice is live in this upload ring.
pub fn (ring &UploadRing) contains(slice UploadSlice) bool {
	if ring.destroyed || slice.owner != voidptr(ring) || isnil(slice.data) {
		return false
	}
	expected := unsafe { voidptr(usize(ring.mapped) + usize(slice.offset)) }
	return slice.data == expected && slice.offset == slice.allocation.offset
		&& slice.size == slice.allocation.size && ring.ranges.contains(slice.allocation)
}

// retire releases the oldest live slice. Call this only after the Vulkan fence
// or timeline value protecting that upload has completed.
pub fn (mut ring UploadRing) retire(slice UploadSlice) bool {
	if !ring.contains(slice) {
		return false
	}
	return ring.ranges.release(slice.allocation)
}

// stats returns current payload, padding, free-space, and peak ring occupancy.
pub fn (ring &UploadRing) stats() generic_pool.RingStats {
	if ring.destroyed {
		return generic_pool.RingStats{}
	}
	return ring.ranges.stats()
}

// destroy invalidates all slices, unmaps and destroys the buffer, and releases
// its dedicated memory. The allocator itself remains usable.
pub fn (mut ring UploadRing) destroy() bool {
	if ring.destroyed {
		return false
	}
	ring.ranges.reset()
	ring.allocator.unmap(mut ring.backing)
	vk.destroy_buffer(ring.allocator.create_info.device, ring.buffer, unsafe { nil })
	released := ring.allocator.release(mut ring.backing)
	ring.mapped = unsafe { nil }
	ring.destroyed = true
	return released
}
