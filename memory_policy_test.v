module vkmemalloc

import antono2.vulkan as vk

fn policy_test_memory(value usize) vk.DeviceMemory {
	return unsafe { voidptr(value) }
}

fn policy_test_properties() vk.PhysicalDeviceMemoryProperties {
	mut props := vk.PhysicalDeviceMemoryProperties{}
	props.memoryHeapCount = 2
	props.memoryHeaps[0] = vk.MemoryHeap{
		size: 256
		flags: u32(vk.MemoryHeapFlagBits.device_local)
	}
	props.memoryHeaps[1] = vk.MemoryHeap{
		size: 1024
	}
	props.memoryTypeCount = 4
	props.memoryTypes[0] = vk.MemoryType{
		propertyFlags: u32(vk.MemoryPropertyFlagBits.device_local)
		heapIndex: 0
	}
	props.memoryTypes[1] = vk.MemoryType{
		propertyFlags: u32(vk.MemoryPropertyFlagBits.host_visible) | u32(vk.MemoryPropertyFlagBits.host_coherent)
		heapIndex: 1
	}
	props.memoryTypes[2] = vk.MemoryType{
		propertyFlags: u32(vk.MemoryPropertyFlagBits.host_visible) | u32(vk.MemoryPropertyFlagBits.host_cached)
		heapIndex: 1
	}
	props.memoryTypes[3] = vk.MemoryType{
		propertyFlags: u32(vk.MemoryPropertyFlagBits.device_local) | u32(vk.MemoryPropertyFlagBits.host_visible) | u32(vk.MemoryPropertyFlagBits.host_coherent)
		heapIndex: 0
	}
	return props
}

fn test_memory_policy_selects_usage_specific_properties() {
	props := policy_test_properties()
	all_types := u32(0b1111)
	gpu := select_memory_type(props, all_types, 16, AllocationOptions{
		usage: .gpu_only
	}) or { panic('GPU memory type should exist') }
	assert gpu.index == 0
	assert gpu.heap_index == 0

	upload := select_memory_type(props, all_types, 16, AllocationOptions{
		usage: .upload
	}) or { panic('upload memory type should exist') }
	assert upload.index == 3

	readback := select_memory_type(props, all_types, 16, AllocationOptions{
		usage: .readback
	}) or { panic('readback memory type should exist') }
	assert readback.index == 2
	assert has_memory_flags(readback.property_flags, memory_flag(.host_cached))
}

fn test_memory_policy_honors_required_preferred_and_avoided_flags() {
	props := policy_test_properties()
	host_visible := memory_flag(.host_visible)
	host_coherent := memory_flag(.host_coherent)
	host_cached := memory_flag(.host_cached)
	choice := select_memory_type(props, 0b1110, 16, AllocationOptions{
		required_flags: host_visible
		preferred_flags: host_cached
		avoided_flags: host_coherent
	}) or { panic('host-visible memory type should exist') }
	assert choice.index == 2

	if _ := select_memory_type(props, 0b0001, 16, AllocationOptions{
		required_flags: host_visible
	}) {
		assert false, 'required properties must never be dropped'
	}
}

fn test_memory_policy_prefers_or_requires_available_budget() {
	props := policy_test_properties()
	options := AllocationOptions{
		usage: .automatic
	}
	snapshot := HeapBudgetSnapshot{
		reported: true
		budgets: [u64(128), 1024]
		usages: [u64(120), 0]
	}
	preferred := ranked_memory_types(props, 0b1011, 16, options, snapshot)
	assert preferred.len == 3
	assert preferred[0].index == 1
	assert preferred[0].within_budget
	assert preferred[0].budget_reported
	assert preferred[0].remaining_budget == 1024

	ignored := ranked_memory_types(props, 0b1011, 16, AllocationOptions{
		usage: .automatic
		budget_policy: .ignore
	}, snapshot)
	assert ignored[0].index == 0
	assert !ignored[0].within_budget

	required := ranked_memory_types(props, 0b1011, 16, AllocationOptions{
		usage: .automatic
		budget_policy: .require_within
	}, snapshot)
	assert required.len == 1
	assert required[0].index == 1
}

fn test_memory_policy_is_deterministic_for_equal_candidates() {
	mut props := policy_test_properties()
	props.memoryTypes[1].propertyFlags = u32(vk.MemoryPropertyFlagBits.host_visible)
	props.memoryTypes[2].propertyFlags = u32(vk.MemoryPropertyFlagBits.host_visible)
	choice := select_memory_type(props, 0b0110, 1, AllocationOptions{}) or {
		panic('memory type should exist')
	}
	assert choice.index == 1
}

fn test_allocator_policy_uses_owned_commitment_as_portable_budget_fallback() {
	props := policy_test_properties()
	mut planner := new_memory_block_pool(256, 4) or { panic(err) }
	_ = planner.add_block(0, 256) or { panic(err) }
	mut allocator := Allocator{
		props: props
		planner: planner
	}
	choice := allocator.select_memory_type(0b0011, 16, AllocationOptions{}) or {
		panic('a memory type should remain available')
	}
	assert choice.index == 1
	assert !choice.budget_reported
	assert choice.within_budget

	heaps := allocator.memory_heaps()
	assert heaps.len == 2
	assert heaps[0].budget == 256
	assert heaps[0].usage == 256
	assert heaps[0].remaining_budget == 0
	assert heaps[0].allocator_committed == 256
	assert heaps[0].allocator_used == 0
}

fn test_require_within_can_reuse_an_over_budget_buffer_block() {
	props := policy_test_properties()
	mut planner := new_memory_block_pool(256, 1) or { panic(err) }
	block_id := planner.add_block(0, 256) or { panic(err) }
	mut allocator := Allocator{
		props: props
		planner: planner
	}
	assert allocator.remember_block(policy_test_memory(1), block_id)
	options := AllocationOptions{
		usage: .gpu_only
		budget_policy: .require_within
	}
	choices := allocator.rank_buffer_memory_types(0b0001, 16, options)
	assert choices.len == 1
	assert !choices[0].within_budget
	mut requirements := vk.MemoryRequirements{
		size: 16
		alignment: 8
		memoryTypeBits: 0b0001
	}
	mut allocation := AllocationInfo{}
	result := allocator.allocate_from_choices(mut requirements, choices, unsafe { nil }, false, options.budget_policy, mut allocation)
	assert result == .success
	assert allocation.memory == voidptr(policy_test_memory(1))
	assert allocation.block_size == 256
	assert allocator.release(mut allocation)
}
