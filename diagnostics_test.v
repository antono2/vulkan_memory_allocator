module vkmemalloc

import antono2.vulkan as vk

fn diagnostic_fake_memory(value usize) vk.DeviceMemory {
	return unsafe { voidptr(value) }
}

fn test_allocator_diagnostics_track_lifecycle_and_bound_the_trace() {
	mut planner := new_memory_block_pool(64, 1) or { panic(err) }
	block_id := planner.add_block(4, 64) or { panic(err) }
	mut allocator := Allocator{
		planner:              planner
		event_trace_capacity: 3
		events:               []AllocatorEvent{cap: 3}
	}
	assert allocator.remember_block(diagnostic_fake_memory(42), block_id)
	allocator.reset_diagnostics()

	mut requirements := vk.MemoryRequirements{
		size:           16
		alignment:      8
		memoryTypeBits: u32(1) << 4
	}
	choices := [MemoryTypeChoice{
		index:      4
		heap_index: 2
	}]
	mut allocation := AllocationInfo{}
	result := allocator.allocate_from_choices(mut requirements, choices, unsafe { nil }, false,
		.buffer, .ignore, mut allocation)
	assert result == .success
	assert !allocation.created_block
	assert allocator.release(mut allocation)

	mut unavailable := vk.MemoryRequirements{
		size:           4
		alignment:      1
		memoryTypeBits: 1
	}
	mut unavailable_allocation := AllocationInfo{}
	assert allocator.allocate_from_choices(mut unavailable, [], unsafe { nil }, false, .buffer,
		.ignore, mut unavailable_allocation) == .error_feature_not_present

	mut invalid := vk.MemoryRequirements{
		size:           4
		memoryTypeBits: 1
	}
	mut invalid_allocation := AllocationInfo{}
	assert allocator.allocate_from_choices(mut invalid, choices, unsafe { nil }, false, .buffer,
		.ignore, mut invalid_allocation) == .error_initialization_failed

	diagnostics := allocator.diagnostics()
	assert diagnostics.current.block_count == 1
	assert diagnostics.current.allocation_count == 0
	assert diagnostics.current.committed == 64
	assert diagnostics.counters.allocation_attempts == 3
	assert diagnostics.counters.allocation_successes == 1
	assert diagnostics.counters.allocation_failures == 2
	assert diagnostics.counters.allocation_releases == 1
	assert diagnostics.counters.requested_bytes == 24
	assert diagnostics.counters.successful_bytes == 16
	assert diagnostics.counters.memory_type_attempts == 1
	assert diagnostics.counters.block_reuses == 1
	assert diagnostics.counters.block_allocations == 0
	assert diagnostics.counters.peak_allocation_count == 1
	assert diagnostics.counters.peak_committed == 64
	assert diagnostics.counters.peak_used == 16
	assert diagnostics.trace_capacity == 3
	assert diagnostics.retained_event_count == 3
	assert diagnostics.dropped_event_count == 1

	events := allocator.recent_events()
	assert events.len == 3
	assert events[0].sequence == 2
	assert events[0].kind == .allocation_released
	assert events[0].resource_class == .buffer
	assert events[1].sequence == 3
	assert events[1].kind == .allocation_failed
	assert events[1].result == .error_feature_not_present
	assert events[1].memory_type == max_u32
	assert events[2].sequence == 4
	assert events[2].kind == .allocation_failed
	assert events[2].result == .error_initialization_failed

	allocator.reset_diagnostics()
	reset := allocator.diagnostics()
	assert reset.counters.allocation_attempts == 0
	assert reset.counters.peak_allocation_count == 0
	assert reset.counters.peak_committed == 64
	assert reset.counters.peak_used == 0
	assert reset.retained_event_count == 0
	assert reset.dropped_event_count == 0
	mut after_reset := vk.MemoryRequirements{
		size:           2
		alignment:      1
		memoryTypeBits: 1
	}
	mut after_reset_allocation := AllocationInfo{}
	assert allocator.allocate_from_choices(mut after_reset, [], unsafe { nil }, false, .buffer,
		.ignore, mut after_reset_allocation) == .error_feature_not_present
	after_reset_events := allocator.recent_events()
	assert after_reset_events.len == 1
	assert after_reset_events[0].sequence == 5
}

fn test_allocator_diagnostics_are_available_when_trace_is_disabled() {
	mut planner := new_memory_block_pool(64, 1) or { panic(err) }
	mut allocator := Allocator{
		planner: planner
	}
	mut requirements := vk.MemoryRequirements{
		size:           8
		alignment:      1
		memoryTypeBits: 1
	}
	mut allocation := AllocationInfo{}
	assert allocator.allocate(mut requirements, .staging, mut allocation) == .error_feature_not_present
	diagnostics := allocator.diagnostics()
	assert diagnostics.counters.allocation_attempts == 1
	assert diagnostics.counters.allocation_failures == 1
	assert diagnostics.trace_capacity == 0
	assert diagnostics.retained_event_count == 0
	assert allocator.recent_events().len == 0
}
