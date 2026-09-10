module vkmemalloc

import antono2.vulkan as vk

pub const max_pools = 256
pub const memory_block = 1024 * 1024

pub struct Allocator {
	create_info AllocatorCreateInfo
	props       vk.PhysicalDeviceMemoryProperties
	api_version u32
mut:
	planner   &MemoryBlockPool = unsafe { nil }
	pools     [max_pools]vk.DeviceMemory
	block_ids [max_pools]u64
	pool_size u32
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
			return true
		}
	}
	if a.pool_size >= max_pools {
		return false
	}
	a.pools[a.pool_size] = memory
	a.block_ids[a.pool_size] = block_id
	a.pool_size++
	return true
}

fn (mut a Allocator) forget_block(block_id u64) ?vk.DeviceMemory {
	for i in 0 .. a.pool_size {
		if a.block_ids[i] == block_id {
			memory := a.pools[i]
			a.pools[i] = unsafe { nil }
			a.block_ids[i] = 0
			for a.pool_size > 0 && isnil(a.pools[a.pool_size - 1]) {
				a.pool_size--
			}
			return memory
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
	// The memory type index
pub mut:
	mem_type u32
	// The memory handle (VkDeviceMemory)
	memory voidptr = unsafe { nil }
	// The offset in the memory block
	offset u64
	// The size reserved for this resource inside the memory block
	size u64
mut:
	reservation BlockReservation
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
	planner := new_memory_block_pool(block_size, block_limit) or {
		panic('invalid Vulkan memory block configuration: ${err}')
	}
	return Allocator{
		create_info: create_info
		props:       mem_props
		api_version: device_props.apiVersion
		planner:     planner
	}
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

	// `alloc_info` is the caller's output record. Rebinding it to a freshly
	// allocated local pointer loses the allocation handle at every call site.
	// Reset and populate that record directly instead.
	alloc_info = AllocationInfo{}

	// Note: VK_NULL_HANDLE is "nullptr", "voidptr(0)" for C++ compatible compilers, or "0ULL" (Unsigned Long Long 0) for 64bit and "0" for 32 bit in C
	alloc_info.memory = unsafe { nil } // vk.null_handle
	alloc_info.size = req.size
	alloc_info.offset = 0
	alloc_info.mem_type = a.get_memory_type(req.memoryTypeBits, mem_type)
	if alloc_info.mem_type == max_u32 {
		// Never drop required properties. In particular, mapping arbitrary
		// device-local memory after a staging allocation fails is invalid and
		// previously led to a null mapped pointer and a delayed segfault.
		eprintln('No compatible Vulkan memory type: type bits 0x${req.memoryTypeBits:08x}, required flags 0x${u32(mem_type):08x}')
		return .error_feature_not_present
	}
	if req.size == 0 || req.alignment == 0 {
		return .error_initialization_failed
	}
	if isnil(a.planner) {
		return .error_initialization_failed
	}

	if !dedicated {
		if reservation := a.planner.reserve(alloc_info.mem_type, req.size, req.alignment) {
			memory := a.memory_for_block(reservation.block_id) or {
				_ = a.planner.release(reservation)
				return .error_initialization_failed
			}
			a.populate_allocation(mut alloc_info, memory, reservation)
			return .success
		}
	}

	if !a.has_free_slot() {
		return .error_too_many_objects
	}
	block_size := if dedicated {
		req.size
	} else {
		a.planner.recommended_block_size(req.size) or { return .error_out_of_device_memory }
	}
	vkalloc_info := vk.MemoryAllocateInfo{
		allocationSize:  block_size
		memoryTypeIndex: alloc_info.mem_type
		pNext:           allocation_pnext
	}
	mut memory := vk.DeviceMemory(unsafe { nil })
	result := vk.allocate_memory(a.create_info.device, &vkalloc_info, unsafe { nil }, &memory)
	if result != .success {
		return result
	}
	block_id := if dedicated {
		a.planner.add_dedicated_block(alloc_info.mem_type, block_size) or {
			vk.free_memory(a.create_info.device, memory, unsafe { nil })
			alloc_info = AllocationInfo{}
			return .error_too_many_objects
		}
	} else {
		a.planner.add_block(alloc_info.mem_type, block_size) or {
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
	return .success
}

fn (a &Allocator) populate_allocation(mut alloc_info AllocationInfo, memory vk.DeviceMemory, reservation BlockReservation) {
	alloc_info.memory = voidptr(memory)
	alloc_info.mem_type = reservation.memory_type
	alloc_info.offset = reservation.offset
	alloc_info.size = reservation.size
	alloc_info.reservation = reservation
}

fn (a &Allocator) owns_allocation(alloc_info AllocationInfo) bool {
	if isnil(alloc_info.memory) || isnil(a.planner) || !a.planner.contains(alloc_info.reservation) {
		return false
	}
	memory := a.memory_for_block(alloc_info.reservation.block_id) or { return false }
	return voidptr(memory) == alloc_info.memory
		&& alloc_info.offset == alloc_info.reservation.offset
		&& alloc_info.size == alloc_info.reservation.size
		&& alloc_info.mem_type == alloc_info.reservation.memory_type
}

fn (mut a Allocator) allocate_buffer_memory(buffer vk.Buffer, type MemType, mut alloc_info AllocationInfo) vk.Result {
	if a.api_version < vk.api_version_1_1 {
		mut requirements := vk.MemoryRequirements{}
		vk.get_buffer_memory_requirements(a.create_info.device, buffer, mut requirements)
		return a.allocate_with_policy(mut requirements, type, unsafe { nil }, false, mut alloc_info)
	}
	mut dedicated_requirements := vk.MemoryDedicatedRequirements{}
	mut requirements := vk.MemoryRequirements2{
		pNext: &dedicated_requirements
	}
	info := vk.BufferMemoryRequirementsInfo2{
		buffer: buffer
	}
	vk.get_buffer_memory_requirements2(a.create_info.device, &info, mut requirements)
	dedicated := dedicated_requirements.requiresDedicatedAllocation == vk._true
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

// create_buffer creates a buffer, suballocates compatible memory, and binds it.
pub fn (mut a Allocator) create_buffer(buffer_info &vk.BufferCreateInfo, type MemType, buffer &vk.Buffer, mut alloc_info AllocationInfo) vk.Result {
	unsafe {
		*buffer = nil
	}
	alloc_info = AllocationInfo{}
	mut res := vk.create_buffer(a.create_info.device, buffer_info, unsafe { nil }, buffer)
	if res != vk.Result.success {
		eprintln('Could not create Vulkan buffer: ${res}')
		return res
	}

	res = a.allocate_buffer_memory(*buffer, type, mut alloc_info)
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

// map maps the allocation's byte range for host access.
pub fn (mut a Allocator) map(mut alloc_info AllocationInfo, data &voidptr) vk.Result {
	if !a.owns_allocation(alloc_info) {
		return .error_memory_map_failed
	}
	return vk.map_memory(a.create_info.device, alloc_info.memory, alloc_info.offset,
		alloc_info.size, 0, data)
}

// unmap unmaps the memory block containing an allocation.
pub fn (mut a Allocator) unmap(mut alloc_info AllocationInfo) {
	if a.owns_allocation(alloc_info) {
		vk.unmap_memory(a.create_info.device, alloc_info.memory)
	}
}

// release returns a tracked suballocation to its VkDeviceMemory block. Empty
// blocks remain cached until trim_empty_blocks() or destroy() is called.
pub fn (mut a Allocator) release(mut alloc_info AllocationInfo) bool {
	if !a.owns_allocation(alloc_info) {
		return false
	}
	if !a.planner.release(alloc_info.reservation) {
		return false
	}
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
	if isnil(a.planner) {
		return 0
	}
	mut removed := 0
	mut index := 0
	for index < int(a.pool_size) {
		block_id := a.block_ids[index]
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
		removed++
	}
	return removed
}

// AllocatorStats reports Vulkan block commitment and live suballocation use.
pub struct AllocatorStats {
pub:
	block_count      int
	allocation_count int
	committed        u64
	used             u64
	free             u64
}

// stats returns current Vulkan commitment and suballocation occupancy.
pub fn (a &Allocator) stats() AllocatorStats {
	if isnil(a.planner) {
		return AllocatorStats{}
	}
	stats := a.planner.stats()
	return AllocatorStats{
		block_count:      stats.block_count
		allocation_count: stats.allocation_count
		committed:        stats.committed
		used:             stats.used
		free:             stats.free
	}
}

// destroy frees every Vulkan memory block owned by the allocator.
pub fn (mut a Allocator) destroy() {
	for i in 0 .. a.pool_size {
		if !isnil(a.pools[i]) {
			vk.free_memory(a.create_info.device, a.pools[i], unsafe { nil })
			a.pools[i] = unsafe { nil }
			a.block_ids[i] = 0
		}
	}
	a.pool_size = 0
	if !isnil(a.planner) {
		a.planner = new_memory_block_pool(a.planner.default_block_size, a.planner.max_blocks) or {
			unsafe { nil }
		}
	}
}
