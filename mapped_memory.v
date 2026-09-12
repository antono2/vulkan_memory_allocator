module vkmemalloc

import antono2.vulkan as vk

struct NormalizedMappedRange {
	offset u64
	size   u64
}

fn normalize_mapped_range(allocation_offset u64, allocation_size u64, block_size u64, relative_offset u64, size u64, atom_size u64) ?NormalizedMappedRange {
	if size == 0 || atom_size == 0 || relative_offset > allocation_size
		|| size > allocation_size - relative_offset {
		return none
	}
	absolute_offset := allocation_offset + relative_offset
	if absolute_offset < allocation_offset || absolute_offset > block_size
		|| size > block_size - absolute_offset {
		return none
	}
	start := absolute_offset - absolute_offset % atom_size
	end := absolute_offset + size
	rounded_end := if end % atom_size == 0 {
		end
	} else if end > max_u64 - (atom_size - end % atom_size) {
		return none
	} else {
		end + atom_size - end % atom_size
	}
	return NormalizedMappedRange{
		offset: start
		size:   if rounded_end >= block_size {
			vk.whole_size
		} else {
			rounded_end - start
		}
	}
}

fn (a &Allocator) mapped_range(alloc_info AllocationInfo, relative_offset u64, size u64) ?vk.MappedMemoryRange {
	if !a.owns_allocation(alloc_info) || !alloc_info.mapped
		|| !has_memory_flags(alloc_info.property_flags, memory_flag(.host_visible)) {
		return none
	}
	normalized := normalize_mapped_range(alloc_info.offset, alloc_info.size, alloc_info.block_size,
		relative_offset, size, a.non_coherent_atom_size) or { return none }
	return vk.MappedMemoryRange{
		memory: vk.DeviceMemory(alloc_info.memory)
		offset: normalized.offset
		size:   normalized.size
	}
}

// flush makes host writes in the whole allocation available to the device.
// Host-coherent memory succeeds without issuing a Vulkan call.
pub fn (a &Allocator) flush(alloc_info AllocationInfo) vk.Result {
	return a.flush_range(alloc_info, 0, alloc_info.size)
}

// flush_range makes one allocation-relative host-written range available to
// the device. The Vulkan range is expanded to nonCoherentAtomSize boundaries.
pub fn (a &Allocator) flush_range(alloc_info AllocationInfo, relative_offset u64, size u64) vk.Result {
	range := a.mapped_range(alloc_info, relative_offset, size) or {
		return .error_memory_map_failed
	}
	if has_memory_flags(alloc_info.property_flags, memory_flag(.host_coherent)) {
		return .success
	}
	return vk.flush_mapped_memory_ranges(a.create_info.device, 1, &range)
}

// invalidate makes device writes in the whole allocation visible to the host.
// Synchronize device access before calling it.
pub fn (a &Allocator) invalidate(alloc_info AllocationInfo) vk.Result {
	return a.invalidate_range(alloc_info, 0, alloc_info.size)
}

// invalidate_range makes one allocation-relative device-written range visible
// to the host and expands it to nonCoherentAtomSize boundaries.
pub fn (a &Allocator) invalidate_range(alloc_info AllocationInfo, relative_offset u64, size u64) vk.Result {
	range := a.mapped_range(alloc_info, relative_offset, size) or {
		return .error_memory_map_failed
	}
	if has_memory_flags(alloc_info.property_flags, memory_flag(.host_coherent)) {
		return .success
	}
	return vk.invalidate_mapped_memory_ranges(a.create_info.device, 1, &range)
}
