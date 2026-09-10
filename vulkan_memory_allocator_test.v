module vkmemalloc

import antono2.vulkan as vk

fn fake_memory(value usize) vk.DeviceMemory {
	return unsafe { voidptr(value) }
}

fn test_freed_pool_slots_are_reused() {
	mut allocator := Allocator{}
	for i in 1 .. max_pools + 1 {
		remembered := allocator.remember_block(fake_memory(usize(i)), u64(i))
		assert remembered
	}
	assert !allocator.has_free_slot()
	forgotten := allocator.forget_block(17) or { panic('block should exist') }
	assert forgotten == fake_memory(17)
	assert allocator.has_free_slot()
	reused := allocator.remember_block(fake_memory(usize(max_pools + 1)), max_pools + 1)
	assert reused
	assert allocator.pool_size == max_pools
}

fn test_releasing_trailing_slots_reduces_high_water_mark() {
	mut allocator := Allocator{}
	first := allocator.remember_block(fake_memory(1), 1)
	second := allocator.remember_block(fake_memory(2), 2)
	third := allocator.remember_block(fake_memory(3), 3)
	assert first
	assert second
	assert third
	_ = allocator.forget_block(2) or { panic('block should exist') }
	assert allocator.pool_size == 3
	_ = allocator.forget_block(3) or { panic('block should exist') }
	assert allocator.pool_size == 1
	if _ := allocator.forget_block(99) {
		assert false, 'unknown block must not be removed'
	}
}

fn test_null_allocation_cannot_be_mapped_or_freed() {
	mut allocator := Allocator{}
	mut allocation := AllocationInfo{}
	mut data := voidptr(unsafe { nil })
	assert allocator.map(mut allocation, &data) == .error_memory_map_failed
	assert !allocator.release(mut allocation)
}

fn test_allocator_release_returns_only_the_suballocated_range() {
	mut planner := new_memory_block_pool(64, 2) or { panic(err) }
	block_id := planner.add_block(4, 64) or { panic(err) }
	first_reservation := planner.reserve(4, 16, 8) or { panic(err) }
	second_reservation := planner.reserve(4, 16, 8) or { panic(err) }
	mut allocator := Allocator{
		planner: planner
	}
	remembered := allocator.remember_block(fake_memory(42), block_id)
	assert remembered
	mut first := AllocationInfo{}
	mut second := AllocationInfo{}
	allocator.populate_allocation(mut first, fake_memory(42), first_reservation)
	allocator.populate_allocation(mut second, fake_memory(42), second_reservation)

	assert first.memory == second.memory
	assert first.offset == 0
	assert second.offset == 16
	before := allocator.stats()
	assert before.block_count == 1
	assert before.allocation_count == 2
	assert before.committed == 64
	assert before.used == 32

	first_released := allocator.release(mut first)
	assert first_released
	assert isnil(first.memory)
	assert !isnil(second.memory)
	after := allocator.stats()
	assert after.block_count == 1
	assert after.allocation_count == 1
	assert after.used == 16
	assert after.free == 48

	second_released := allocator.release(mut second)
	assert second_released
	assert allocator.stats().allocation_count == 0
}

fn test_allocator_rejects_forged_public_allocation_fields() {
	mut planner := new_memory_block_pool(32, 1) or { panic(err) }
	block_id := planner.add_block(1, 32) or { panic(err) }
	reservation := planner.reserve(1, 8, 1) or { panic(err) }
	mut allocator := Allocator{
		planner: planner
	}
	remembered := allocator.remember_block(fake_memory(7), block_id)
	assert remembered
	mut allocation := AllocationInfo{}
	allocator.populate_allocation(mut allocation, fake_memory(7), reservation)
	allocation.offset++

	mut mapped := voidptr(unsafe { nil })
	assert allocator.map(mut allocation, &mapped) == .error_memory_map_failed
	assert !allocator.release(mut allocation)
	assert allocator.stats().allocation_count == 1
}
