module vulkan_memory_allocator

import vulkan as vk
import dlmalloc as dm

pub const max_pools = 256
pub const memory_block = 1024 * 1024


pub struct Allocator {
  create_info AllocatorCreateInfo
  limits vk.PhysicalDeviceLimits
  props vk.PhysicalDeviceMemoryProperties
mut:
  dlmalloc dm.Dlmalloc
  head &MemNode = unsafe{ nil }
  tail &MemNode = unsafe{ nil }
  vk_memory_requirements vk.MemoryRequirements
  pools [max_pools]vk.DeviceMemory
  pool_size u32
}

enum MemType {
// Memory that is accessible from the CPU and GPU 
	staging
// Memory that is only available from the GPU 
	gpu
}

@[heap]
pub struct Alloc {
pub mut:
// The memory type 
	mem_type u32
// The memory handle 
	memory /*vk.DeviceMemory*/ voidptr = unsafe{nil}
// The offset in the memory block 
	offset usize
// The size of the memory block. Bigger than requested size 
	size usize
}

struct MemNode {
pub mut:
	alloc &Alloc = unsafe {nil}
	next &MemNode = unsafe { nil }
}

pub struct AllocatorCreateInfo {
pub mut:
  physical_device /*vk.PhysicalDevice*/ voidptr = unsafe{ nil }
  device /*vk.Device*/ voidptr = unsafe{ nil }
 }

pub fn new(create_info AllocatorCreateInfo) Allocator {
  mut gpu_props := vk.PhysicalDeviceProperties{}
  vk.get_physical_device_properties(create_info.physical_device, mut &gpu_props)
  limits := gpu_props.limits
  mut mem_props := vk.PhysicalDeviceMemoryProperties{}
  vk.get_physical_device_memory_properties(create_info.physical_device, mut &mem_props)
  return Allocator{create_info: create_info, limits: limits, props: mem_props, dlmalloc: dm.new(dm.get_system_allocator())}
}

pub fn (mut a Allocator) get_memory_type(type_bits u32, mem_props vk.MemoryPropertyFlags) u32 {
  mut param_type_bits := type_bits
  for i in 0 .. a.props.memoryTypeCount {
    if (param_type_bits & 1) == 1 {
      if (a.props.memoryTypes[i].propertyFlags & mem_props) == mem_props {
        return i
      }
    }
    param_type_bits >>= 1
  }
  return max_u32
}

pub fn (mut a Allocator) mem_insert(alloc &Alloc) vk.Result {
  mut node := unsafe{ &MemNode(a.dlmalloc.malloc(sizeof(MemNode))) }
  if isnil(node) {
    return .error_out_of_host_memory
  }
  node.alloc = unsafe{ alloc }
  node.next = unsafe{ nil }

  if isnil(a.head) {
    a.head = node
  }
  if !isnil(a.tail) {
    a.tail.next = node
  }
  return .success 
}

pub fn (mut a Allocator) allocate(req vk.MemoryRequirements, type MemType, mut alloc &Alloc) vk.Result {
  mut mem_type := vk.MemoryPropertyFlags(0)
  mut res := vk.Result.success
  mut node := &MemNode{}
  mut last := &MemNode{}

  match type {
    .staging {
      mem_type = int(vk.MemoryPropertyFlagBits.host_visible_bit) | int(vk.MemoryPropertyFlagBits.host_coherent_bit)
    }
    .gpu {
      mem_type = vk.MemoryPropertyFlags(vk.MemoryPropertyFlagBits.device_local_bit)
    }
  }

  unsafe{alloc = a.dlmalloc.malloc(sizeof(Alloc))}
  if isnil(alloc) {
    res = .error_out_of_host_memory
    goto err_return
  }

  // Note: VK_NULL_HANDLE is "nullptr", "voidptr(0)" for C++ compatible compilers, or "0ULL" (Unsigned Long Long 0) for 64bit and "0" for 32 bit in C. Not sure what to do about that yet
  alloc.memory = voidptr(0) //vk.null_handle
  alloc.size = req.size + (req.size % a.limits.bufferImageGranularity)
  alloc.mem_type = a.get_memory_type(req.memoryTypeBits, mem_type)
  if alloc.mem_type == max_u32 {
    res = .error_unknown
    goto err_alloc
  }

  node = a.head
  last = unsafe{nil}
  for !isnil(node) {
    if node.alloc.mem_type == alloc.mem_type && node.alloc.size == alloc.size {
      alloc.memory = node.alloc.memory
      alloc.offset = node.alloc.offset
      if node.alloc.size == alloc.size {
        if !isnil(last) {
          last.next = node.next
        } else {
          a.head = node.next
        }
        a.dlmalloc.free(node.alloc)
        a.dlmalloc.free(node)
      } else {
        node.alloc.offset += alloc.size
        node.alloc.size -= alloc.size
      }
      break
    }
    last = node
    node = node.next
  }

  if isnil(alloc.memory) {
    mut count := u32(1)
    for count * memory_block < alloc.size { count += 1}
    mut alloc_info := vk.MemoryAllocateInfo {
      allocationSize: count * memory_block
      memoryTypeIndex: alloc.mem_type
    }
    
    alloc.offset = 0

    res = vk.allocate_memory(a.create_info.device, &alloc_info, unsafe{nil}, &alloc.memory)if res != .success {
      goto err_alloc
    }

    mut allocation := unsafe{&Alloc(a.dlmalloc.malloc(sizeof(Alloc)))}
    if isnil(allocation) {
      res = .error_out_of_host_memory
    }
    allocation.mem_type = alloc.mem_type
    allocation.memory = alloc.memory
    allocation.offset = alloc.size
    allocation.size = count * memory_block - alloc.size

    res = a.mem_insert(allocation)
    if res != .success {
      free(allocation)
      goto err_mem
    }

    a.pools[a.pool_size] = alloc.memory
    a.pool_size += 1
  }
  return vk.Result.success

err_mem:
  vk.free_memory(a.create_info.device, alloc.memory, unsafe{nil})
err_alloc:
  free(alloc)
err_return:  
  return res
}

pub fn (mut a Allocator) create_buffer(buffer_info &vk.BufferCreateInfo, type MemType, buffer &vk.Buffer, mut alloc &Alloc) vk.Result {
  mut req := vk.MemoryRequirements{}
  mut res := vk.create_buffer(a.create_info.device, buffer_info, unsafe{nil}, buffer)
  if res != .success {
    goto err_return
  }

  vk.get_buffer_memory_requirements(a.create_info.device, *buffer, mut &req)
  res = a.allocate(req, type, mut alloc)
  if res != .success {
    goto err_buffer
  }

  res = vk.bind_buffer_memory(a.create_info.device, *buffer, alloc.memory, alloc.offset)
  if res != .success {
    goto err_buffer
  }
err_buffer:
  vk.destroy_buffer(a.create_info.device, *buffer, unsafe{nil})
err_return:
  return res
}




