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
import dlmalloc as dm

pub const max_pools = 256
pub const memory_block = 1024 * 1024


pub struct Allocator {
  create_info AllocatorCreateInfo
  limits vk.PhysicalDeviceLimits
  //props vk.PhysicalDeviceMemoryProperties
  props vk.PhysicalDeviceMemoryProperties2
mut:
  dlmalloc dm.Dlmalloc
  head &MemNode = unsafe{ nil }
  tail &MemNode = unsafe{ nil }
  vk_memory_requirements vk.MemoryRequirements
  pools [max_pools]vk.DeviceMemory
  pool_size u32
  didnt_find_mem_type_index bool = false
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
// The memory handle
	memory /*vk.DeviceMemory*/ voidptr = unsafe{nil}
// The offset in the memory block
	offset u64
// The size of the memory block. Bigger than requested size
	size u64
}

pub struct MemNode {
pub mut:
	alloc_info &AllocationInfo = unsafe {nil}
	next &MemNode = unsafe { nil }
}

pub struct AllocatorCreateInfo {
pub mut:
  physical_device vk.PhysicalDevice
  device vk.Device
}

pub fn new(create_info AllocatorCreateInfo) Allocator {
  mut gpu_props := vk.PhysicalDeviceProperties{}
  vk.get_physical_device_properties(create_info.physical_device, mut &gpu_props)
  limits := gpu_props.limits
  //mut mem_props := vk.PhysicalDeviceMemoryProperties{}
  //vk.get_physical_device_memory_properties(create_info.physical_device, mut &mem_props)
  // It's assumed that vulkan version > 1.0
  mut mem_props := vk.PhysicalDeviceMemoryProperties2{}
  // Note: get_physical_device_memory_properties, non 2 version, is depricated since vulkan 1.1
  vk.get_physical_device_memory_properties2(create_info.physical_device, mut &mem_props)
  return Allocator{create_info: create_info, limits: limits, props: mem_props, dlmalloc: dm.new(dm.get_system_allocator())}
}

// memoryTypeBits is an 32bit integer that contains one bit set for every SUPPORTED memory type for the resource
// It comes from vkGet..MemoryRequirements functions.
//
// At index n of the vk.PhysicalDeviceMemoryProperties.memoryTypes array,
// checked for matching propertyFlags and return the current n if they match
// Note: The memoryTypeBits member always contains at least one bit set
pub fn (mut a Allocator) get_memory_type(type_bits_param u32, mem_props vk.MemoryPropertyFlags) u32 {
  mut type_bits := type_bits_param
  for i in 0 .. a.props.memoryProperties.memoryTypeCount {
    // Check if memory at index is available
    if (type_bits & 1) == 1 {
      // Check if the requirements - marked by set bits in mem_props - match the available memory property flags
      if (a.props.memoryProperties.memoryTypes[i].propertyFlags & mem_props) == mem_props {
        if mem_props == 0 {
          dump('First available memory type index ${i}')
        }
        return i
      }
    }
    type_bits >>>= 1
  }
  return max_u32
}

fn (mut a Allocator) mem_insert(mut alloc_info AllocationInfo) vk.Result {
  mut node := unsafe{ &MemNode(a.dlmalloc.malloc(sizeof(MemNode))) }
  if isnil(node) {
    return .error_out_of_host_memory
  }
  node.alloc_info = unsafe{ alloc_info }
  node.next = unsafe{ nil }

  if isnil(a.head) {
    a.head = node
  }
  if !isnil(a.tail) {
    a.tail.next = node
  }
  return .success 
}

pub fn (mut a Allocator) allocate(mut req vk.MemoryRequirements, type MemType, mut alloc_info AllocationInfo) vk.Result {
  mut mem_type := vk.MemoryPropertyFlags(0)
  mut res := vk.Result.success
  mut node := &MemNode{}
  mut last := &MemNode{}

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

  alloc_info = unsafe{ &AllocationInfo(a.dlmalloc.malloc(sizeof(AllocationInfo))) }
  if isnil(alloc_info) {
    res = .error_out_of_host_memory
    goto err_return
  }

  // Note: VK_NULL_HANDLE is "nullptr", "voidptr(0)" for C++ compatible compilers, or "0ULL" (Unsigned Long Long 0) for 64bit and "0" for 32 bit in C
  alloc_info.memory = unsafe{nil} //vk.null_handle
  alloc_info.size = req.size + (req.size % a.limits.bufferImageGranularity)
  alloc_info.mem_type = a.get_memory_type(req.memoryTypeBits, mem_type)
  if alloc_info.mem_type == max_u32 && !a.didnt_find_mem_type_index {
    if !a.didnt_find_mem_type_index {
      a.didnt_find_mem_type_index = true
      dump('Memory type index for given requirements not found. Trying first available.')
      return a.allocate(mut req, MemType.first_available, mut alloc_info)
    } else {
      a.didnt_find_mem_type_index = false
      res = .error_unknown
      dump('Could not find suitable memory slot index for required MemoryPropertyFlags')
      goto err_alloc
    }
  }

  node = a.head
  last = unsafe{nil}
  for !isnil(node) {
    if node.alloc_info.mem_type == alloc_info.mem_type && node.alloc_info.size == alloc_info.size {
      alloc_info.memory = node.alloc_info.memory
      alloc_info.offset = node.alloc_info.offset
      if node.alloc_info.size == alloc_info.size {
        if !isnil(last) {
          last.next = node.next
        } else {
          a.head = node.next
        }
        dm.free(node.alloc_info)
        dm.free(node)
      } else {
        node.alloc_info.offset += alloc_info.size
        node.alloc_info.size -= alloc_info.size
      }
      break
    }
    last = node
    node = node.next
  }

  if isnil(alloc_info.memory) {
    mut count := u32(1)
    for count * memory_block < alloc_info.size { count++}
    mut vkalloc_info := vk.MemoryAllocateInfo {
      allocationSize: count * memory_block
      memoryTypeIndex: alloc_info.mem_type
    }
    
    alloc_info.offset = 0

    res = vk.allocate_memory(a.create_info.device, &vkalloc_info, unsafe{nil}, &alloc_info.memory)
    if res != .success {
      dump('vk.allocate_memory error')
      goto err_alloc
    }

    mut vkalloc := unsafe{ &AllocationInfo(a.dlmalloc.malloc(sizeof(AllocationInfo))) }
    if isnil(vkalloc) {
      res = .error_out_of_host_memory
    }
    vkalloc.mem_type = alloc_info.mem_type
    vkalloc.memory = alloc_info.memory
    vkalloc.offset = alloc_info.size
    vkalloc.size = count * memory_block - alloc_info.size

    res = a.mem_insert(mut vkalloc)
    if res != .success {
      dump('a.mem_insert error')
      free(vkalloc)
      goto err_mem
    }

    a.pools[a.pool_size] = alloc_info.memory
    a.pool_size += 1
  }
  return vk.Result.success

err_mem:
  vk.free_memory(a.create_info.device, alloc_info.memory, unsafe{nil})
  dump('Freed memory, err_mem')
err_alloc:
  free(alloc_info)
  dump('Freed alloc_info, err_alloc')
err_return:
  dump('Err return allocate')
  return res
}

pub fn (mut a Allocator) create_buffer(buffer_info &vk.BufferCreateInfo, type MemType, mut buffer vk.Buffer, mut alloc_info AllocationInfo) vk.Result {
  mut req := vk.MemoryRequirements{}
  mut res := vk.create_buffer(a.create_info.device, buffer_info, unsafe{nil}, buffer)
  if res != vk.Result.success {
    dump('Err create_buffer vk.create_buffer ${res}')
    goto err_return
  }

  vk.get_buffer_memory_requirements(a.create_info.device, buffer, mut &req)
  res = a.allocate(mut req, type, mut alloc_info)
  if res != vk.Result.success {
    dump('Err create_buffer a.allocate')
    goto err_buffer
  }

  res = vk.bind_buffer_memory(a.create_info.device, buffer, alloc_info.memory, alloc_info.offset)
  if res != vk.Result.success {
    dump('Err create_buffer vk.bind_buffer_memory')
    goto err_buffer
  }
  
  return vk.Result.success

err_buffer:
  vk.destroy_buffer(a.create_info.device, buffer, unsafe{nil})
  buffer = unsafe{nil}
err_return:
  return res
}

pub fn (mut a Allocator) create_image(p_image_create_info &vk.ImageCreateInfo, type MemType, p_image &vk.Image, mut alloc_info AllocationInfo) vk.Result {
  mut req := vk.MemoryRequirements{}
  mut res := vk.create_image(a.create_info.device, p_image_create_info, unsafe{nil}, p_image)
  if res != vk.Result.success {
    goto err_return
  }

  vk.get_image_memory_requirements(a.create_info.device, *p_image, mut req)
  res = a.allocate(mut req, type, mut alloc_info)
  if res != vk.Result.success {
    goto err_image
  }

  res = vk.bind_image_memory(a.create_info.device, *p_image, alloc_info.memory, alloc_info.offset)
  if res != vk.Result.success {
    goto err_image
  }
  return vk.Result.success
  
err_image:
  vk.destroy_image(a.create_info.device, *p_image, unsafe{nil})
err_return:
  return res
}

pub fn (mut a Allocator) map(mut alloc_info AllocationInfo, data &voidptr) vk.Result {
  return vk.map_memory(a.create_info.device, alloc_info.memory, alloc_info.offset, alloc_info.size, 0, data)
}

pub fn (mut a Allocator) unmap(mut alloc_info AllocationInfo) {
  vk.unmap_memory(a.create_info.device, alloc_info.memory)
}

pub fn (mut a Allocator) allocator_free(mut alloc_info AllocationInfo) {
  a.mem_insert(mut alloc_info)
}

pub fn (mut a Allocator) destroy() {
  mut node := &MemNode{}

  for i in 0..a.pool_size {
    vk.free_memory(a.create_info.device, a.pools[i], unsafe{nil})
  }

  node = a.head

  for !isnil(node) {
    mut tmp := node
    node = node.next
    free(tmp.alloc_info)
    free(tmp)
  }
}

