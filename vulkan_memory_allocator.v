/*
  Provides basic functionality to allocate memory on the GPU.

  First create a new Allocator and get the vulkan memory requirements for your session.
  pub fn new(create_info AllocatorCreateInfo) Allocator
  vulkan.get_..._memory_requirements_khr(...)

  Then you can use these to allocate and bind the memory.
  pub fn (mut a Allocator) allocate(mut req vulkan.MemoryRequirements, type MemType, mut alloc_info AllocationInfo) vulkan.Result
  vulkan.bind_..._session_memory_khr(...)

  Use the Allocator to create a buffer or image.
  pub fn (mut a Allocator) create_buffer(buffer_info &vulkan.BufferCreateInfo, type MemType, mut buffer vulkan.Buffer, mut alloc_info AllocationInfo) vulkan.Result
  pub fn (mut a Allocator) create_image(p_image_create_info &vulkan.ImageCreateInfo, type MemType, p_image &vulkan.Image, mut alloc_info AllocationInfo) vulkan.Result

  And map to access them from CPU.
  pub fn (mut a Allocator) map(mut alloc_info AllocationInfo, data &voidptr) vulkan.Result
*/
module vulkan_memory_allocator

import vulkan as vk

pub const max_pools = 256
pub const memory_block = 1024 * 1024

pub struct Allocator {
	create_info AllocatorCreateInfo
	props       vk.PhysicalDeviceMemoryProperties
mut:
	vk_memory_requirements vk.MemoryRequirements
	pools                  [max_pools]vk.DeviceMemory
	pool_size              u32
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

fn (mut a Allocator) remember_memory(memory vk.DeviceMemory) bool {
	for i in 0 .. a.pool_size {
		if isnil(a.pools[i]) {
			a.pools[i] = memory
			return true
		}
	}
	if a.pool_size >= max_pools {
		return false
	}
	a.pools[a.pool_size] = memory
	a.pool_size++
	return true
}

fn (mut a Allocator) forget_memory(memory vk.DeviceMemory) bool {
	for i in 0 .. a.pool_size {
		if a.pools[i] == memory {
			a.pools[i] = unsafe { nil }
			for a.pool_size > 0 && isnil(a.pools[a.pool_size - 1]) {
				a.pool_size--
			}
			return true
		}
	}
	return false
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
	// The size of the memory block. Bigger than requested size
	size u64
}

pub struct MemNode {
pub mut:
	alloc_info &AllocationInfo = unsafe { nil }
	next       &MemNode = unsafe { nil }
}

pub struct AllocatorCreateInfo {
pub mut:
	physical_device vk.PhysicalDevice
	device          vk.Device
}

pub fn new(create_info AllocatorCreateInfo) Allocator {
	// The core query works on every Vulkan version and avoids relying on the
	// caller having initialized the sType of a Properties2 wrapper correctly.
	mut mem_props := vk.PhysicalDeviceMemoryProperties{}
	vk.get_physical_device_memory_properties(create_info.physical_device, mut &mem_props)
	return Allocator{
		create_info: create_info
		props: mem_props
	}
}

// memoryTypeBits is an 32bit integer that contains one bit set for every SUPPORTED memory type for the resource
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

pub fn (mut a Allocator) allocate(mut req vk.MemoryRequirements, type MemType, mut alloc_info AllocationInfo) vk.Result {
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
	if !a.has_free_slot() {
		return .error_too_many_objects
	}
	vkalloc_info := vk.MemoryAllocateInfo{
		allocationSize: alloc_info.size
		memoryTypeIndex: alloc_info.mem_type
	}
	result := vk.allocate_memory(a.create_info.device, &vkalloc_info, unsafe { nil }, &alloc_info.memory)
	if result == .success {
		if !a.remember_memory(alloc_info.memory) {
			vk.free_memory(a.create_info.device, alloc_info.memory, unsafe { nil })
			alloc_info = AllocationInfo{}
			return .error_too_many_objects
		}
	}
	return result
}

pub fn (mut a Allocator) create_buffer(buffer_info &vk.BufferCreateInfo, type MemType, mut buffer vk.Buffer, mut alloc_info AllocationInfo) vk.Result {
	buffer = unsafe { nil }
	alloc_info = AllocationInfo{}
	mut req := vk.MemoryRequirements{}
	mut res := vk.create_buffer(a.create_info.device, buffer_info, unsafe { nil }, buffer)
	if res != vk.Result.success {
		eprintln('Could not create Vulkan buffer: ${res}')
		return res
	}

	vk.get_buffer_memory_requirements(a.create_info.device, buffer, mut &req)
	res = a.allocate(mut req, type, mut alloc_info)
	if res != vk.Result.success {
		eprintln('Could not allocate Vulkan buffer memory: ${res}')
		vk.destroy_buffer(a.create_info.device, buffer, unsafe { nil })
		buffer = unsafe { nil }
		return res
	}

	res = vk.bind_buffer_memory(a.create_info.device, buffer, alloc_info.memory, alloc_info.offset)
	if res != vk.Result.success {
		eprintln('Could not bind Vulkan buffer memory: ${res}')
		vk.destroy_buffer(a.create_info.device, buffer, unsafe { nil })
		buffer = unsafe { nil }
		a.allocator_free(mut alloc_info)
		return res
	}

	return vk.Result.success
}

pub fn (mut a Allocator) create_image(p_image_create_info &vk.ImageCreateInfo, type MemType, p_image &vk.Image, mut alloc_info AllocationInfo) vk.Result {
	unsafe { *p_image = nil }
	alloc_info = AllocationInfo{}
	mut req := vk.MemoryRequirements{}
	mut res := vk.create_image(a.create_info.device, p_image_create_info, unsafe { nil }, p_image)
	if res != vk.Result.success {
		eprintln('Could not create Vulkan image: ${res}')
		return res
	}

	vk.get_image_memory_requirements(a.create_info.device, *p_image, mut req)
	res = a.allocate(mut req, type, mut alloc_info)
	if res != vk.Result.success {
		eprintln('Could not allocate Vulkan image memory: ${res}')
		vk.destroy_image(a.create_info.device, *p_image, unsafe { nil })
		unsafe { *p_image = nil }
		return res
	}

	res = vk.bind_image_memory(a.create_info.device, *p_image, alloc_info.memory, alloc_info.offset)
	if res != vk.Result.success {
		eprintln('Could not bind Vulkan image memory: ${res}')
		vk.destroy_image(a.create_info.device, *p_image, unsafe { nil })
		unsafe { *p_image = nil }
		a.allocator_free(mut alloc_info)
		return res
	}
	return vk.Result.success
}

pub fn (mut a Allocator) map(mut alloc_info AllocationInfo, data &voidptr) vk.Result {
	if isnil(alloc_info.memory) {
		return .error_memory_map_failed
	}
	return vk.map_memory(a.create_info.device, alloc_info.memory, alloc_info.offset, alloc_info.size, 0, data)
}

pub fn (mut a Allocator) unmap(mut alloc_info AllocationInfo) {
	if !isnil(alloc_info.memory) {
		vk.unmap_memory(a.create_info.device, alloc_info.memory)
	}
}

// release frees a tracked allocation. It returns false when the allocation is
// null or belongs to a different allocator.
pub fn (mut a Allocator) release(mut alloc_info AllocationInfo) bool {
	if isnil(alloc_info.memory) || !a.forget_memory(alloc_info.memory) {
		return false
	}
	vk.free_memory(a.create_info.device, alloc_info.memory, unsafe { nil })
	alloc_info = AllocationInfo{}
	return true
}

// allocator_free is retained for source compatibility. New code should use
// release() so an ownership mismatch can be detected.
pub fn (mut a Allocator) allocator_free(mut alloc_info AllocationInfo) {
	_ = a.release(mut alloc_info)
}

pub fn (mut a Allocator) destroy() {
	for i in 0 .. a.pool_size {
		if !isnil(a.pools[i]) {
			vk.free_memory(a.create_info.device, a.pools[i], unsafe { nil })
			a.pools[i] = unsafe { nil }
		}
	}
	a.pool_size = 0
}
