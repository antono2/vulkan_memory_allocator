module vkmemalloc

import antono2.vulkan as vk

fn mapped_test_memory(value usize) vk.DeviceMemory {
	return unsafe { voidptr(value) }
}

fn test_mapped_range_aligns_both_ends_to_atom_size() {
	range := normalize_mapped_range(128, 512, 1024, 3, 130, 64) or {
		panic('range should be valid')
	}
	assert range.offset == 128
	assert range.size == 192
}

fn test_mapped_range_uses_whole_size_at_memory_end() {
	range := normalize_mapped_range(768, 256, 1024, 240, 16, 64) or {
		panic('range should be valid')
	}
	assert range.offset == 960
	assert range.size == vk.whole_size
}

fn test_mapped_range_rejects_empty_or_out_of_allocation_ranges() {
	if _ := normalize_mapped_range(128, 256, 1024, 0, 0, 64) {
		assert false, 'empty ranges must be rejected'
	}
	if _ := normalize_mapped_range(128, 256, 1024, 250, 7, 64) {
		assert false, 'ranges must remain inside the allocation'
	}
	if _ := normalize_mapped_range(900, 200, 1024, 0, 200, 64) {
		assert false, 'allocations must remain inside their memory block'
	}
}

fn test_coherent_flush_validates_ownership_without_a_driver_call() {
	mut props := vk.PhysicalDeviceMemoryProperties{}
	props.memoryHeapCount = 1
	props.memoryHeaps[0].size = 256
	props.memoryTypeCount = 1
	props.memoryTypes[0] = vk.MemoryType{
		propertyFlags: u32(vk.MemoryPropertyFlagBits.host_visible) | u32(vk.MemoryPropertyFlagBits.host_coherent)
		heapIndex:     0
	}
	mut planner := new_memory_block_pool(256, 1) or { panic(err) }
	block_id := planner.add_block(0, 256) or { panic(err) }
	reservation := planner.reserve(0, 64, 1) or { panic(err) }
	mut allocator := Allocator{
		props:                  props
		non_coherent_atom_size: 64
		planner:                planner
	}
	assert allocator.remember_block(mapped_test_memory(1), block_id)
	mut allocation := AllocationInfo{}
	allocator.populate_allocation(mut allocation, mapped_test_memory(1), reservation)
	allocation.mapped = true
	assert allocator.flush_range(allocation, 1, 1) == .success
	assert allocator.invalidate(allocation) == .success
	assert allocator.flush_range(allocation, allocation.size, 1) == .error_memory_map_failed

	allocation.property_flags = 0
	assert allocator.flush(allocation) == .error_memory_map_failed
}
