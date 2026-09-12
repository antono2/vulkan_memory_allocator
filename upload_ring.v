module vkmemalloc

import antono2.memory
import antono2.vulkan as vk

// UploadSlice identifies one persistently mapped staging-buffer range. Slices
// must be retired in allocation order after the GPU no longer reads them.
pub struct UploadSlice {
	owner      voidptr
	allocation memory.RingAllocation
pub:
	offset u64
	size   u64
	data   voidptr
}

// UploadRingStats describes current payload, alignment/wrap padding, free
// space, and peak occupancy without exposing the underlying policy type.
pub struct UploadRingStats {
pub:
	capacity                u64
	used                    u64
	payload                 u64
	padding                 u64
	free                    u64
	peak_used               u64
	allocation_count        int
	largest_contiguous_free u64
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
	mapped    voidptr = unsafe { nil }
	ranges    &memory.RingAllocator = unsafe { nil }
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
		size: capacity
		usage: u32(vk.BufferUsageFlagBits.transfer_src)
		sharingMode: .exclusive
	}
	mut buffer := vk.Buffer(unsafe { nil })
	mut backing := AllocationInfo{}
	result := allocator.create_dedicated_buffer(&buffer_info, .staging, &buffer, mut backing)
	if result != .success {
		return error('could not create upload buffer: ${result}')
	}
	return finish_upload_ring(mut allocator, capacity, buffer, backing)
}

// new_upload_ring_with_options creates an upload ring with policy-selected
// host-visible memory. Prefer usage .upload; callers using a non-coherent type
// must flush each written slice before device access.
pub fn new_upload_ring_with_options(mut allocator Allocator, capacity u64, options AllocationOptions) !&UploadRing {
	if capacity == 0 {
		return error('upload ring capacity must be greater than zero')
	}
	$if x32 {
		if capacity > u64(max_u32) {
			return error('upload ring capacity exceeds the host address space')
		}
	}
	buffer_info := vk.BufferCreateInfo{
		size: capacity
		usage: u32(vk.BufferUsageFlagBits.transfer_src)
		sharingMode: .exclusive
	}
	effective_options := AllocationOptions{
		usage: options.usage
		required_flags: options.required_flags | memory_flag(.host_visible)
		preferred_flags: options.preferred_flags
		avoided_flags: options.avoided_flags
		budget_policy: options.budget_policy
	}
	mut buffer := vk.Buffer(unsafe { nil })
	mut backing := AllocationInfo{}
	result := allocator.create_dedicated_buffer_with_options(&buffer_info, effective_options, &buffer, mut backing)
	if result != .success {
		return error('could not create upload buffer: ${result}')
	}
	return finish_upload_ring(mut allocator, capacity, buffer, backing)
}

fn finish_upload_ring(mut allocator Allocator, capacity u64, buffer vk.Buffer, initial_backing AllocationInfo) !&UploadRing {
	mut backing := initial_backing
	mut mapped := voidptr(unsafe { nil })
	map_result := allocator.map(mut backing, &mapped)
	if map_result != .success {
		vk.destroy_buffer(allocator.create_info.device, buffer, unsafe { nil })
		_ = allocator.release(mut backing)
		return error('could not map upload buffer: ${map_result}')
	}
	return &UploadRing{
		buffer: buffer
		capacity: capacity
		allocator: allocator
		backing: backing
		mapped: mapped
		ranges: memory.new_ring_allocator(capacity)
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
		owner: ring
		allocation: allocation
		offset: allocation.offset
		size: allocation.size
		data: data
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

// flush makes host writes in a live slice available to the device. It is a
// no-op for the coherent memory used by new_upload_ring(), but keeps upload
// code correct if the backing policy changes.
pub fn (ring &UploadRing) flush(slice UploadSlice) vk.Result {
	if !ring.contains(slice) {
		return .error_memory_map_failed
	}
	return ring.allocator.flush_range(ring.backing, slice.offset, slice.size)
}

// invalidate makes device writes in a live slice visible to the host.
pub fn (ring &UploadRing) invalidate(slice UploadSlice) vk.Result {
	if !ring.contains(slice) {
		return .error_memory_map_failed
	}
	return ring.allocator.invalidate_range(ring.backing, slice.offset, slice.size)
}

// stats returns current payload, padding, free-space, and peak ring occupancy.
pub fn (ring &UploadRing) stats() UploadRingStats {
	if ring.destroyed {
		return UploadRingStats{}
	}
	stats := ring.ranges.stats()
	return UploadRingStats{
		capacity: stats.capacity
		used: stats.used
		payload: stats.payload
		padding: stats.padding
		free: stats.free
		peak_used: stats.peak_used
		allocation_count: stats.allocation_count
		largest_contiguous_free: stats.largest_contiguous_free
	}
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
