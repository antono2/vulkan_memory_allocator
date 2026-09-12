module vkmemalloc

import antono2.vulkan as vk

pub const max_pools = 256
pub const memory_block = 1024 * 1024

pub struct Allocator {
	create_info            AllocatorCreateInfo
	api_version            u32
	non_coherent_atom_size u64
	event_trace_capacity   int
mut:
	props                  vk.PhysicalDeviceMemoryProperties
	planner                &MemoryBlockPool = unsafe { nil }
	pools                  [max_pools]vk.DeviceMemory
	block_ids              [max_pools]u64
	mapped                 [max_pools]voidptr
	map_refs               [max_pools]u32
	pool_size              u32
	memory_budget_reported bool
	heap_budgets           []u64
	heap_usages            []u64
	counters_              AllocatorCounterState
	events                 []AllocatorEvent
	event_cursor           int
	next_event_sequence    u64 = 1
	dropped_event_count    u64
	diagnostic_live_count  int
	diagnostic_live_used   u64
	diagnostic_committed   u64
}

fn (a &Allocator) has_free_slot() bool {
	if a.pool_size < max_pools {
		return true
	}
	for i in 0 .. a.pool_size {
		if isnil(a.pools[i]) {
			return true
		}
	}
	return false
}

fn (mut a Allocator) remember_block(memory vk.DeviceMemory, block_id u64) bool {
	if block_id == 0 {
		return false
	}
	for i in 0 .. a.pool_size {
		if isnil(a.pools[i]) {
			a.pools[i] = memory
			a.block_ids[i] = block_id
			a.mapped[i] = unsafe { nil }
			a.map_refs[i] = 0
			return true
		}
	}
	if a.pool_size >= max_pools {
		return false
	}
	a.pools[a.pool_size] = memory
	a.block_ids[a.pool_size] = block_id
	a.mapped[a.pool_size] = unsafe { nil }
	a.map_refs[a.pool_size] = 0
	a.pool_size++
	return true
}

fn (mut a Allocator) forget_block(block_id u64) ?vk.DeviceMemory {
	for i in 0 .. a.pool_size {
		if a.block_ids[i] == block_id {
			memory := a.pools[i]
			a.pools[i] = unsafe { nil }
			a.block_ids[i] = 0
			a.mapped[i] = unsafe { nil }
			a.map_refs[i] = 0
			for a.pool_size > 0 && isnil(a.pools[a.pool_size - 1]) {
				a.pool_size--
			}
			return memory
		}
	}
	return none
}

fn (a &Allocator) block_index(block_id u64) ?int {
	for i in 0 .. a.pool_size {
		if a.block_ids[i] == block_id && !isnil(a.pools[i]) {
			return int(i)
		}
	}
	return none
}

fn (a &Allocator) memory_for_block(block_id u64) ?vk.DeviceMemory {
	for i in 0 .. a.pool_size {
		if a.block_ids[i] == block_id && !isnil(a.pools[i]) {
			return a.pools[i]
		}
	}
	return none
}

pub enum MemType {
	// Memory that is accessible from the CPU and GPU
	staging
	// Memory that is only available from the GPU
	gpu
	// get_memory_type() will return the first
	// memory slot index with the bit set in memoryTypeBits
	// and not check any properties of that memory slot
	first_available
}

pub struct AllocationInfo {
pub mut:
	// The memory type index
	mem_type u32
	// The Vulkan memory heap backing that type.
	heap_index u32
	// Properties of the selected memory type.
	property_flags vk.MemoryPropertyFlags
	// The memory handle (VkDeviceMemory)
	memory voidptr = unsafe { nil }
	// The offset in the memory block
	offset u64
	// The size reserved for this resource inside the memory block
	size u64
	// Total size of the VkDeviceMemory block containing this allocation.
	block_size u64
mut:
	reservation   BlockReservation
	mapped        bool
	created_block bool
}

pub struct MemNode {
pub mut:
	alloc_info &AllocationInfo = unsafe { nil }
	next       &MemNode        = unsafe { nil }
}

pub struct AllocatorCreateInfo {
pub mut:
	physical_device vk.PhysicalDevice
	device          vk.Device
	// Preferred size for shared VkDeviceMemory blocks. Requests larger than
	// this value receive a correspondingly larger block.
	preferred_block_size u64 = memory_block
	// Maximum number of live VkDeviceMemory blocks, capped by max_pools.
	max_memory_blocks int = max_pools
	// Enable VK_EXT_memory_budget property queries. Set this only when the
	// physical device reports support and the device extension is enabled.
	memory_budget_enabled bool
	// Retain this many recent allocation/release/trim events. Zero (the
	// default) disables the trace; cumulative diagnostics remain available.
	event_trace_capacity int
}

// new creates a Vulkan allocator with memory-type-specific shared blocks.
pub fn new(create_info AllocatorCreateInfo) Allocator {
	// The core query works on every Vulkan version and avoids relying on the
	// caller having initialized the sType of a Properties2 wrapper correctly.
	mut mem_props := vk.PhysicalDeviceMemoryProperties{}
	vk.get_physical_device_memory_properties(create_info.physical_device, mut &mem_props)
	mut device_props := vk.PhysicalDeviceProperties{}
	vk.get_physical_device_properties(create_info.physical_device, mut &device_props)
	block_size := if create_info.preferred_block_size == 0 {
		u64(memory_block)
	} else {
		create_info.preferred_block_size
	}
	block_limit := if create_info.max_memory_blocks <= 0
		|| create_info.max_memory_blocks > max_pools {
		max_pools
	} else {
		create_info.max_memory_blocks
	}
	mut planner := new_memory_block_pool(block_size, block_limit) or {
		panic('invalid Vulkan memory block configuration: ${err}')
	}
	mut allocator := Allocator{
		create_info:            create_info
		props:                  mem_props
		api_version:            device_props.apiVersion
		non_coherent_atom_size: if device_props.limits.nonCoherentAtomSize > 0 {
			u64(device_props.limits.nonCoherentAtomSize)
		} else {
			u64(1)
		}
		planner:                planner
		event_trace_capacity:   if create_info.event_trace_capacity > 0 {
			create_info.event_trace_capacity
		} else {
			0
		}
		events:                 []AllocatorEvent{cap: if create_info.event_trace_capacity > 0 {
			create_info.event_trace_capacity
		} else {
			0
		}}
	}
	if create_info.memory_budget_enabled {
		_ = allocator.refresh_memory_budget()
	}
	return allocator
}

// get_memory_type selects a supported memory type containing every requested
// property flag. memoryTypeBits has one bit set for each type supported by the
// resource.
// It comes from vkGet..MemoryRequirements functions.
//
// At index n of the vk.PhysicalDeviceMemoryProperties.memoryTypes array,
// checked for matching propertyFlags and return the current n if they match
// Note: The memoryTypeBits member always contains at least one bit set
pub fn (mut a Allocator) get_memory_type(type_bits_param u32, mem_props vk.MemoryPropertyFlags) u32 {
	mut type_bits := type_bits_param
	for i in 0 .. a.props.memoryTypeCount {
		// Check if memory at index is available
		if (type_bits & 1) == 1 {
			// Check if the requirements - marked by set bits in mem_props - match the available memory property flags
			if (a.props.memoryTypes[i].propertyFlags & mem_props) == mem_props {
				return i
			}
		}
		type_bits >>>= 1
	}
	return max_u32
}

// allocate reserves an isolated block because raw requirements do not identify
// the resource class needed for safe Vulkan granularity decisions. Prefer
// create_buffer() to enable compatible buffer suballocation.
pub fn (mut a Allocator) allocate(mut req vk.MemoryRequirements, type MemType, mut alloc_info AllocationInfo) vk.Result {
	return a.allocate_with_policy(mut req, type, unsafe { nil }, true, mut alloc_info)
}

fn (mut a Allocator) allocate_with_policy(mut req vk.MemoryRequirements, type MemType, allocation_pnext voidptr, dedicated bool, mut alloc_info AllocationInfo) vk.Result {
	mut mem_type := vk.MemoryPropertyFlags(0)
	match type {
		.staging {
			mem_type = vk.MemoryPropertyFlags(u32(vk.MemoryPropertyFlagBits.host_visible) | u32(vk.MemoryPropertyFlagBits.host_coherent))
		}
		.gpu {
			mem_type = vk.MemoryPropertyFlags(vk.MemoryPropertyFlagBits.device_local)
		}
		.first_available {
			mem_type = 0
		}
	}

	memory_type := a.get_memory_type(req.memoryTypeBits, mem_type)
	if memory_type == max_u32 {
		// Never drop required properties. In particular, mapping arbitrary
		// device-local memory after a staging allocation fails is invalid and
		// previously led to a null mapped pointer and a delayed segfault.
		eprintln('No compatible Vulkan memory type: type bits 0x${req.memoryTypeBits:08x}, required flags 0x${u32(mem_type):08x}')
		return a.allocate_from_choices(mut req, [], allocation_pnext, dedicated, .ignore, mut
			alloc_info)
	}
	choices := ranked_memory_types(a.props, u32(1) << memory_type, req.size, AllocationOptions{
		budget_policy: .ignore
	}, a.heap_budget_snapshot())
	return a.allocate_from_choices(mut req, choices, allocation_pnext, dedicated, .ignore, mut
		alloc_info)
}

// allocate_with_options reserves isolated memory using the portable ranked
// policy. Prefer create_buffer_with_options() when safe buffer suballocation is
// desired.
pub fn (mut a Allocator) allocate_with_options(mut req vk.MemoryRequirements, options AllocationOptions, mut alloc_info AllocationInfo) vk.Result {
	choices := a.rank_memory_types(req.memoryTypeBits, req.size, options)
	return a.allocate_from_choices(mut req, choices, unsafe { nil }, true, options.budget_policy, mut
		alloc_info)
}

fn (mut a Allocator) allocate_from_choices(mut req vk.MemoryRequirements, choices []MemoryTypeChoice, allocation_pnext voidptr, dedicated bool, budget_policy BudgetPolicy, mut alloc_info AllocationInfo) vk.Result {
	// `alloc_info` is the caller's output record. Reset and populate that record
	// directly so callers always receive the actual tracked handle.
	alloc_info = AllocationInfo{}
	a.begin_allocation(req.size)
	if req.size == 0 || req.alignment == 0 {
		result := vk.Result.error_initialization_failed
		a.note_allocation_failure(result, req.size, max_u32, max_u32, dedicated)
		return result
	}
	if isnil(a.planner) {
		result := vk.Result.error_initialization_failed
		a.note_allocation_failure(result, req.size, max_u32, max_u32, dedicated)
		return result
	}
	if choices.len == 0 {
		result := vk.Result.error_feature_not_present
		a.note_allocation_failure(result, req.size, max_u32, max_u32, dedicated)
		return result
	}
	mut last_result := vk.Result.error_out_of_device_memory
	mut last_memory_type := max_u32
	mut last_heap_index := max_u32
	for choice_index, choice in choices {
		last_memory_type = choice.index
		last_heap_index = choice.heap_index
		allow_new_block := budget_policy != .require_within || choice.within_budget
		a.note_memory_type_attempt(choice_index > 0)
		mut result := a.allocate_for_memory_type(mut req, choice, allocation_pnext, dedicated,
			allow_new_block, budget_policy, mut alloc_info)
		if result == .success {
			a.note_allocation_success(alloc_info, dedicated)
			return .success
		}
		last_result = result
		if result !in [.error_out_of_device_memory, .error_out_of_host_memory,
			.error_too_many_objects] {
			a.note_allocation_failure(result, req.size, choice.index, choice.heap_index, dedicated)
			return result
		}
		mut trimmed := 0
		if allow_new_block {
			trimmed = a.trim_empty_blocks_for_heap(choice.heap_index)
			if result == .error_too_many_objects {
				// The block-count cap is allocator-wide, so an empty block in a
				// different heap can also make room for this candidate.
				trimmed += a.trim_empty_blocks()
			}
		}
		if trimmed > 0 {
			a.counters_.trim_retry_attempts++
			a.note_memory_type_attempt(choice_index > 0)
			result = a.allocate_for_memory_type(mut req, choice, allocation_pnext, dedicated, true,
				budget_policy, mut alloc_info)
			if result == .success {
				a.note_allocation_success(alloc_info, dedicated)
				return .success
			}
			last_result = result
		}
		if result == .error_too_many_objects {
			a.note_allocation_failure(result, req.size, choice.index, choice.heap_index, dedicated)
			return result
		}
	}
	a.note_allocation_failure(last_result, req.size, last_memory_type, last_heap_index, dedicated)
	return last_result
}

fn (mut a Allocator) allocate_for_memory_type(mut req vk.MemoryRequirements, choice MemoryTypeChoice, allocation_pnext voidptr, dedicated bool, allow_new_block bool, budget_policy BudgetPolicy, mut alloc_info AllocationInfo) vk.Result {
	if !dedicated {
		if reservation := a.planner.reserve(choice.index, req.size, req.alignment) {
			memory := a.memory_for_block(reservation.block_id) or {
				_ = a.planner.release(reservation)
				return .error_initialization_failed
			}
			a.populate_allocation(mut alloc_info, memory, reservation)
			alloc_info.created_block = false
			a.counters_.block_reuses++
			return .success
		}
	}
	if !allow_new_block {
		return .error_out_of_device_memory
	}
	if !a.has_free_slot() {
		return .error_too_many_objects
	}
	mut block_size := if dedicated {
		req.size
	} else {
		a.planner.recommended_block_size(req.size) or { return .error_out_of_device_memory }
	}
	if budget_policy != .ignore && choice.budget_reported && choice.within_budget
		&& choice.remaining_budget < block_size {
		block_size = choice.remaining_budget
	}
	vkalloc_info := vk.MemoryAllocateInfo{
		allocationSize:  block_size
		memoryTypeIndex: choice.index
		pNext:           allocation_pnext
	}
	mut memory := vk.DeviceMemory(unsafe { nil })
	result := vk.allocate_memory(a.create_info.device, &vkalloc_info, unsafe { nil }, &memory)
	if result != .success {
		return result
	}
	block_id := if dedicated {
		a.planner.add_dedicated_block(choice.index, block_size) or {
			vk.free_memory(a.create_info.device, memory, unsafe { nil })
			alloc_info = AllocationInfo{}
			return .error_too_many_objects
		}
	} else {
		a.planner.add_block(choice.index, block_size) or {
			vk.free_memory(a.create_info.device, memory, unsafe { nil })
			alloc_info = AllocationInfo{}
			return .error_too_many_objects
		}
	}
	if !a.remember_block(memory, block_id) {
		_ = a.planner.remove_empty_block(block_id)
		vk.free_memory(a.create_info.device, memory, unsafe { nil })
		alloc_info = AllocationInfo{}
		return .error_too_many_objects
	}
	reservation := a.planner.reserve_from_block(block_id, req.size, req.alignment) or {
		_ = a.forget_block(block_id)
		_ = a.planner.remove_empty_block(block_id)
		vk.free_memory(a.create_info.device, memory, unsafe { nil })
		alloc_info = AllocationInfo{}
		return .error_out_of_device_memory
	}
	a.populate_allocation(mut alloc_info, memory, reservation)
	alloc_info.created_block = true
	a.counters_.block_allocations++
	return .success
}

fn (a &Allocator) populate_allocation(mut alloc_info AllocationInfo, memory vk.DeviceMemory, reservation BlockReservation) {
	alloc_info.memory = voidptr(memory)
	alloc_info.mem_type = reservation.memory_type
	if reservation.memory_type < a.props.memoryTypeCount {
		memory_type := a.props.memoryTypes[reservation.memory_type]
		alloc_info.heap_index = memory_type.heapIndex
		alloc_info.property_flags = memory_type.propertyFlags
	}
	alloc_info.offset = reservation.offset
	alloc_info.size = reservation.size
	alloc_info.block_size = a.planner.block_capacity(reservation.block_id) or { 0 }
	alloc_info.reservation = reservation
}

fn (a &Allocator) owns_allocation(alloc_info AllocationInfo) bool {
	if isnil(alloc_info.memory) || isnil(a.planner) || !a.planner.contains(alloc_info.reservation) {
		return false
	}
	memory := a.memory_for_block(alloc_info.reservation.block_id) or { return false }
	if alloc_info.mem_type < a.props.memoryTypeCount {
		memory_type := a.props.memoryTypes[alloc_info.mem_type]
		if alloc_info.heap_index != memory_type.heapIndex
			|| alloc_info.property_flags != memory_type.propertyFlags {
			return false
		}
	}
	return voidptr(memory) == alloc_info.memory && alloc_info.offset == alloc_info.reservation.offset && alloc_info.size == alloc_info.reservation.size && alloc_info.mem_type == alloc_info.reservation.memory_type && alloc_info.block_size == (a.planner.block_capacity(alloc_info.reservation.block_id) or {
		return false
	})
}

fn (mut a Allocator) allocate_buffer_memory(buffer vk.Buffer, type MemType, force_dedicated bool, mut alloc_info AllocationInfo) vk.Result {
	if a.api_version < vk.api_version_1_1 {
		mut requirements := vk.MemoryRequirements{}
		vk.get_buffer_memory_requirements(a.create_info.device, buffer, mut requirements)
		return a.allocate_with_policy(mut requirements, type, unsafe { nil }, force_dedicated, mut
			alloc_info)
	}
	mut dedicated_requirements := vk.MemoryDedicatedRequirements{}
	mut requirements := vk.MemoryRequirements2{
		pNext: &dedicated_requirements
	}
	info := vk.BufferMemoryRequirementsInfo2{
		buffer: buffer
	}
	vk.get_buffer_memory_requirements2(a.create_info.device, &info, mut requirements)
	dedicated := force_dedicated || dedicated_requirements.requiresDedicatedAllocation == vk._true
		|| dedicated_requirements.prefersDedicatedAllocation == vk._true
	if !dedicated {
		return a.allocate_with_policy(mut requirements.memoryRequirements, type, unsafe { nil },
			false, mut alloc_info)
	}
	dedicated_info := vk.MemoryDedicatedAllocateInfo{
		buffer: buffer
	}
	return a.allocate_with_policy(mut requirements.memoryRequirements, type,
		voidptr(&dedicated_info), true, mut alloc_info)
}

fn (mut a Allocator) allocate_buffer_memory_with_options(buffer vk.Buffer, options AllocationOptions, force_dedicated bool, mut alloc_info AllocationInfo) vk.Result {
	if a.api_version < vk.api_version_1_1 {
		mut requirements := vk.MemoryRequirements{}
		vk.get_buffer_memory_requirements(a.create_info.device, buffer, mut requirements)
		choices := if force_dedicated {
			a.rank_memory_types(requirements.memoryTypeBits, requirements.size, options)
		} else {
			a.rank_buffer_memory_types(requirements.memoryTypeBits, requirements.size, options)
		}
		return a.allocate_from_choices(mut requirements, choices, unsafe { nil }, force_dedicated,
			options.budget_policy, mut alloc_info)
	}
	mut dedicated_requirements := vk.MemoryDedicatedRequirements{}
	mut requirements := vk.MemoryRequirements2{
		pNext: &dedicated_requirements
	}
	info := vk.BufferMemoryRequirementsInfo2{
		buffer: buffer
	}
	vk.get_buffer_memory_requirements2(a.create_info.device, &info, mut requirements)
	dedicated := force_dedicated || dedicated_requirements.requiresDedicatedAllocation == vk._true
		|| dedicated_requirements.prefersDedicatedAllocation == vk._true
	choices := if dedicated {
		a.rank_memory_types(requirements.memoryRequirements.memoryTypeBits,
			requirements.memoryRequirements.size, options)
	} else {
		a.rank_buffer_memory_types(requirements.memoryRequirements.memoryTypeBits,
			requirements.memoryRequirements.size, options)
	}
	if !dedicated {
		return a.allocate_from_choices(mut requirements.memoryRequirements, choices,
			unsafe { nil }, false, options.budget_policy, mut alloc_info)
	}
	dedicated_info := vk.MemoryDedicatedAllocateInfo{
		buffer: buffer
	}
	return a.allocate_from_choices(mut requirements.memoryRequirements, choices,
		voidptr(&dedicated_info), true, options.budget_policy, mut alloc_info)
}

fn (mut a Allocator) allocate_image_memory(image vk.Image, type MemType, mut alloc_info AllocationInfo) vk.Result {
	mut requirements := vk.MemoryRequirements{}
	if a.api_version >= vk.api_version_1_1 {
		mut requirements2 := vk.MemoryRequirements2{}
		info := vk.ImageMemoryRequirementsInfo2{
			image: image
		}
		vk.get_image_memory_requirements2(a.create_info.device, &info, mut requirements2)
		requirements = requirements2.memoryRequirements
		dedicated_info := vk.MemoryDedicatedAllocateInfo{
			image: image
		}
		return a.allocate_with_policy(mut requirements, type, voidptr(&dedicated_info), true, mut
			alloc_info)
	}
	vk.get_image_memory_requirements(a.create_info.device, image, mut requirements)
	return a.allocate_with_policy(mut requirements, type, unsafe { nil }, true, mut alloc_info)
}

fn (mut a Allocator) allocate_image_memory_with_options(image vk.Image, options AllocationOptions, mut alloc_info AllocationInfo) vk.Result {
	mut requirements := vk.MemoryRequirements{}
	if a.api_version >= vk.api_version_1_1 {
		mut requirements2 := vk.MemoryRequirements2{}
		info := vk.ImageMemoryRequirementsInfo2{
			image: image
		}
		vk.get_image_memory_requirements2(a.create_info.device, &info, mut requirements2)
		requirements = requirements2.memoryRequirements
		choices := a.rank_memory_types(requirements.memoryTypeBits, requirements.size, options)
		dedicated_info := vk.MemoryDedicatedAllocateInfo{
			image: image
		}
		return a.allocate_from_choices(mut requirements, choices, voidptr(&dedicated_info), true,
			options.budget_policy, mut alloc_info)
	}
	vk.get_image_memory_requirements(a.create_info.device, image, mut requirements)
	choices := a.rank_memory_types(requirements.memoryTypeBits, requirements.size, options)
	return a.allocate_from_choices(mut requirements, choices, unsafe { nil }, true,
		options.budget_policy, mut alloc_info)
}

// create_buffer creates a buffer, suballocates compatible memory, and binds it.
pub fn (mut a Allocator) create_buffer(buffer_info &vk.BufferCreateInfo, type MemType, buffer &vk.Buffer, mut alloc_info AllocationInfo) vk.Result {
	return a.create_buffer_with_policy(buffer_info, type, false, buffer, mut alloc_info)
}

// create_dedicated_buffer creates a buffer with an isolated memory block. Use
// it for persistent mapping, external memory, or explicit lifetime isolation.
pub fn (mut a Allocator) create_dedicated_buffer(buffer_info &vk.BufferCreateInfo, type MemType, buffer &vk.Buffer, mut alloc_info AllocationInfo) vk.Result {
	return a.create_buffer_with_policy(buffer_info, type, true, buffer, mut alloc_info)
}

// create_buffer_with_options creates a buffer and selects memory using an
// explicit usage/property/budget policy. Compatible buffers share blocks.
pub fn (mut a Allocator) create_buffer_with_options(buffer_info &vk.BufferCreateInfo, options AllocationOptions, buffer &vk.Buffer, mut alloc_info AllocationInfo) vk.Result {
	return a.create_buffer_with_options_policy(buffer_info, options, false, buffer, mut alloc_info)
}

// create_dedicated_buffer_with_options is the policy-based counterpart of
// create_dedicated_buffer().
pub fn (mut a Allocator) create_dedicated_buffer_with_options(buffer_info &vk.BufferCreateInfo, options AllocationOptions, buffer &vk.Buffer, mut alloc_info AllocationInfo) vk.Result {
	return a.create_buffer_with_options_policy(buffer_info, options, true, buffer, mut alloc_info)
}

fn (mut a Allocator) create_buffer_with_options_policy(buffer_info &vk.BufferCreateInfo, options AllocationOptions, dedicated bool, buffer &vk.Buffer, mut alloc_info AllocationInfo) vk.Result {
	unsafe {
		*buffer = nil
	}
	alloc_info = AllocationInfo{}
	mut result := vk.create_buffer(a.create_info.device, buffer_info, unsafe { nil }, buffer)
	if result != .success {
		return result
	}
	result = a.allocate_buffer_memory_with_options(*buffer, options, dedicated, mut alloc_info)
	if result != .success {
		vk.destroy_buffer(a.create_info.device, *buffer, unsafe { nil })
		unsafe {
			*buffer = nil
		}
		return result
	}
	result = vk.bind_buffer_memory(a.create_info.device, *buffer, alloc_info.memory,
		alloc_info.offset)
	if result != .success {
		vk.destroy_buffer(a.create_info.device, *buffer, unsafe { nil })
		unsafe {
			*buffer = nil
		}
		_ = a.release(mut alloc_info)
	}
	return result
}

fn (mut a Allocator) create_buffer_with_policy(buffer_info &vk.BufferCreateInfo, type MemType, dedicated bool, buffer &vk.Buffer, mut alloc_info AllocationInfo) vk.Result {
	unsafe {
		*buffer = nil
	}
	alloc_info = AllocationInfo{}
	mut res := vk.create_buffer(a.create_info.device, buffer_info, unsafe { nil }, buffer)
	if res != vk.Result.success {
		eprintln('Could not create Vulkan buffer: ${res}')
		return res
	}

	res = a.allocate_buffer_memory(*buffer, type, dedicated, mut alloc_info)
	if res != vk.Result.success {
		eprintln('Could not allocate Vulkan buffer memory: ${res}')
		vk.destroy_buffer(a.create_info.device, *buffer, unsafe { nil })
		unsafe {
			*buffer = nil
		}
		return res
	}

	res = vk.bind_buffer_memory(a.create_info.device, *buffer, alloc_info.memory, alloc_info.offset)
	if res != vk.Result.success {
		eprintln('Could not bind Vulkan buffer memory: ${res}')
		vk.destroy_buffer(a.create_info.device, *buffer, unsafe { nil })
		unsafe {
			*buffer = nil
		}
		a.allocator_free(mut alloc_info)
		return res
	}

	return vk.Result.success
}

// create_image creates an image, suballocates compatible memory, and binds it.
pub fn (mut a Allocator) create_image(p_image_create_info &vk.ImageCreateInfo, type MemType, p_image &vk.Image, mut alloc_info AllocationInfo) vk.Result {
	unsafe {
		*p_image = nil
	}
	alloc_info = AllocationInfo{}
	mut res := vk.create_image(a.create_info.device, p_image_create_info, unsafe { nil }, p_image)
	if res != vk.Result.success {
		eprintln('Could not create Vulkan image: ${res}')
		return res
	}

	res = a.allocate_image_memory(*p_image, type, mut alloc_info)
	if res != vk.Result.success {
		eprintln('Could not allocate Vulkan image memory: ${res}')
		vk.destroy_image(a.create_info.device, *p_image, unsafe { nil })
		unsafe {
			*p_image = nil
		}
		return res
	}

	res = vk.bind_image_memory(a.create_info.device, *p_image, alloc_info.memory, alloc_info.offset)
	if res != vk.Result.success {
		eprintln('Could not bind Vulkan image memory: ${res}')
		vk.destroy_image(a.create_info.device, *p_image, unsafe { nil })
		unsafe {
			*p_image = nil
		}
		a.allocator_free(mut alloc_info)
		return res
	}
	return vk.Result.success
}

// create_image_with_options creates a dedicated image allocation using the
// ranked usage/property/budget policy. Image suballocation remains deliberately
// conservative because buffer-image granularity and tiling compatibility must
// be tracked together.
pub fn (mut a Allocator) create_image_with_options(image_info &vk.ImageCreateInfo, options AllocationOptions, image &vk.Image, mut alloc_info AllocationInfo) vk.Result {
	unsafe {
		*image = nil
	}
	alloc_info = AllocationInfo{}
	mut result := vk.create_image(a.create_info.device, image_info, unsafe { nil }, image)
	if result != .success {
		return result
	}
	result = a.allocate_image_memory_with_options(*image, options, mut alloc_info)
	if result != .success {
		vk.destroy_image(a.create_info.device, *image, unsafe { nil })
		unsafe {
			*image = nil
		}
		return result
	}
	result = vk.bind_image_memory(a.create_info.device, *image, alloc_info.memory,
		alloc_info.offset)
	if result != .success {
		vk.destroy_image(a.create_info.device, *image, unsafe { nil })
		unsafe {
			*image = nil
		}
		_ = a.release(mut alloc_info)
	}
	return result
}

// map maps the allocation's byte range for host access. Compatible allocations
// sharing one VkDeviceMemory block share one Vulkan mapping internally.
pub fn (mut a Allocator) map(mut alloc_info AllocationInfo, data &voidptr) vk.Result {
	if !a.owns_allocation(alloc_info) {
		eprintln('Cannot map an allocation not owned by this allocator')
		return .error_memory_map_failed
	}
	if !has_memory_flags(alloc_info.property_flags, memory_flag(.host_visible)) {
		eprintln('Cannot map memory without the host-visible property')
		return .error_memory_map_failed
	}
	if alloc_info.mapped {
		eprintln('Cannot map an allocation that is already mapped')
		return .error_memory_map_failed
	}
	index := a.block_index(alloc_info.reservation.block_id) or {
		eprintln('Cannot map an allocation whose memory block is unavailable')
		return .error_memory_map_failed
	}
	if isnil(a.mapped[index]) {
		mut base := voidptr(unsafe { nil })
		result := vk.map_memory(a.create_info.device, alloc_info.memory, 0, vk.whole_size, 0, &base)
		if result != .success {
			eprintln('Could not map Vulkan memory block ${alloc_info.reservation.block_id}: ${result}')
			return result
		}
		a.mapped[index] = base
	}
	unsafe {
		*data = voidptr(usize(a.mapped[index]) + usize(alloc_info.offset))
	}
	a.map_refs[index]++
	alloc_info.mapped = true
	return .success
}

// unmap releases this allocation's mapping reference. The Vulkan memory block
// remains mapped until every mapped suballocation has been unmapped.
pub fn (mut a Allocator) unmap(mut alloc_info AllocationInfo) {
	if !a.owns_allocation(alloc_info) || !alloc_info.mapped {
		return
	}
	index := a.block_index(alloc_info.reservation.block_id) or { return }
	if a.map_refs[index] > 0 {
		a.map_refs[index]--
	}
	if a.map_refs[index] == 0 && !isnil(a.mapped[index]) {
		vk.unmap_memory(a.create_info.device, a.pools[index])
		a.mapped[index] = unsafe { nil }
	}
	alloc_info.mapped = false
}

// release returns a tracked suballocation to its VkDeviceMemory block. Empty
// shared blocks remain cached; dedicated blocks are freed immediately.
pub fn (mut a Allocator) release(mut alloc_info AllocationInfo) bool {
	if !a.owns_allocation(alloc_info) {
		return false
	}
	if alloc_info.mapped {
		a.unmap(mut alloc_info)
	}
	block_id := alloc_info.reservation.block_id
	dedicated := a.planner.block_is_dedicated(block_id) or { return false }
	if !a.planner.release(alloc_info.reservation) {
		return false
	}
	released_info := alloc_info
	if dedicated {
		memory := a.memory_for_block(block_id) or { return false }
		if !a.planner.remove_empty_block(block_id) {
			return false
		}
		_ = a.forget_block(block_id) or { return false }
		vk.free_memory(a.create_info.device, memory, unsafe { nil })
		a.counters_.block_frees++
	}
	a.note_allocation_release(released_info, dedicated)
	alloc_info = AllocationInfo{}
	return true
}

// allocator_free is retained for source compatibility. New code should use
// release() so an ownership mismatch can be detected.
pub fn (mut a Allocator) allocator_free(mut alloc_info AllocationInfo) {
	_ = a.release(mut alloc_info)
}

// trim_empty_blocks frees cached VkDeviceMemory blocks with no live ranges.
pub fn (mut a Allocator) trim_empty_blocks() int {
	return a.trim_empty_blocks_filtered(0, false)
}

fn (mut a Allocator) trim_empty_blocks_for_heap(heap_index u32) int {
	return a.trim_empty_blocks_filtered(heap_index, true)
}

fn (mut a Allocator) trim_empty_blocks_filtered(heap_index u32, filter_by_heap bool) int {
	if isnil(a.planner) {
		return 0
	}
	mut removed := 0
	mut index := 0
	for index < int(a.pool_size) {
		block_id := a.block_ids[index]
		memory_type := a.planner.block_memory_type(block_id) or {
			index++
			continue
		}
		if filter_by_heap && (memory_type >= a.props.memoryTypeCount
			|| a.props.memoryTypes[memory_type].heapIndex != heap_index) {
			index++
			continue
		}
		allocation_count := a.planner.block_allocation_count(block_id) or {
			index++
			continue
		}
		if allocation_count != 0 {
			index++
			continue
		}
		memory := a.memory_for_block(block_id) or {
			index++
			continue
		}
		block_size := a.planner.block_capacity(block_id) or {
			index++
			continue
		}
		heap := if memory_type < a.props.memoryTypeCount {
			a.props.memoryTypes[memory_type].heapIndex
		} else {
			max_u32
		}
		if !a.planner.remove_empty_block(block_id) {
			index++
			continue
		}
		_ = a.forget_block(block_id) or {
			// Both lookups use the same private block table, so this indicates
			// corrupted allocator state. Keep the handle rather than freeing an
			// object that can no longer be accounted for.
			return removed
		}
		vk.free_memory(a.create_info.device, memory, unsafe { nil })
		a.note_block_trimmed(memory_type, heap, block_size)
		removed++
	}
	return removed
}

// AllocatorStats reports Vulkan block commitment, live suballocation use, and
// free-range fragmentation. largest_free_range is the largest raw contiguous
// range and does not account for the alignment of a future request.
pub struct AllocatorStats {
pub:
	block_count        int
	allocation_count   int
	committed          u64
	used               u64
	free               u64
	free_range_count   int
	largest_free_range u64
	empty_block_count  int
}

// stats returns current Vulkan commitment and suballocation occupancy.
pub fn (a &Allocator) stats() AllocatorStats {
	if isnil(a.planner) {
		return AllocatorStats{}
	}
	stats := a.planner.stats()
	return AllocatorStats{
		block_count:        stats.block_count
		allocation_count:   stats.allocation_count
		committed:          stats.committed
		used:               stats.used
		free:               stats.free
		free_range_count:   stats.free_range_count
		largest_free_range: stats.largest_free_range
		empty_block_count:  stats.empty_block_count
	}
}

// stats_for_memory_type returns commitment, occupancy, and fragmentation for
// one Vulkan memory-type index. Use this instead of global stats when
// diagnosing whether compatible blocks can satisfy a resource request.
pub fn (a &Allocator) stats_for_memory_type(memory_type u32) AllocatorStats {
	if isnil(a.planner) {
		return AllocatorStats{}
	}
	stats := a.planner.stats_for_memory_type(memory_type)
	return AllocatorStats{
		block_count:        stats.block_count
		allocation_count:   stats.allocation_count
		committed:          stats.committed
		used:               stats.used
		free:               stats.free
		free_range_count:   stats.free_range_count
		largest_free_range: stats.largest_free_range
		empty_block_count:  stats.empty_block_count
	}
}

// destroy frees every Vulkan memory block owned by the allocator.
pub fn (mut a Allocator) destroy() {
	for i in 0 .. a.pool_size {
		if !isnil(a.pools[i]) {
			if !isnil(a.mapped[i]) {
				vk.unmap_memory(a.create_info.device, a.pools[i])
				a.mapped[i] = unsafe { nil }
				a.map_refs[i] = 0
			}
			vk.free_memory(a.create_info.device, a.pools[i], unsafe { nil })
			a.counters_.block_frees++
			a.pools[i] = unsafe { nil }
			a.block_ids[i] = 0
		}
	}
	a.pool_size = 0
	a.diagnostic_live_count = 0
	a.diagnostic_live_used = 0
	a.diagnostic_committed = 0
	if !isnil(a.planner) {
		a.planner = new_memory_block_pool(a.planner.default_block_size, a.planner.max_blocks) or {
			unsafe { nil }
		}
	}
}
