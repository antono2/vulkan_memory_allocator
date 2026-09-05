module vulkan_memory_allocator

import vulkan as vk

fn fake_memory(value usize) vk.DeviceMemory {
	return unsafe { voidptr(value) }
}

fn test_freed_pool_slots_are_reused() {
	mut allocator := Allocator{}
	for i in 1 .. max_pools + 1 {
		assert allocator.remember_memory(fake_memory(usize(i)))
	}
	assert !allocator.has_free_slot()
	assert allocator.forget_memory(fake_memory(usize(17)))
	assert allocator.has_free_slot()
	assert allocator.remember_memory(fake_memory(usize(max_pools + 1)))
	assert allocator.pool_size == max_pools
}

fn test_releasing_trailing_slots_reduces_high_water_mark() {
	mut allocator := Allocator{}
	assert allocator.remember_memory(fake_memory(1))
	assert allocator.remember_memory(fake_memory(2))
	assert allocator.remember_memory(fake_memory(3))
	assert allocator.forget_memory(fake_memory(2))
	assert allocator.pool_size == 3
	assert allocator.forget_memory(fake_memory(3))
	assert allocator.pool_size == 1
	assert !allocator.forget_memory(fake_memory(99))
}

fn test_null_allocation_cannot_be_mapped_or_freed() {
	mut allocator := Allocator{}
	mut allocation := AllocationInfo{}
	mut data := voidptr(unsafe { nil })
	assert allocator.map(mut allocation, &data) == .error_memory_map_failed
	assert !allocator.release(mut allocation)
}
