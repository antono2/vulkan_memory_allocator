module vkmemalloc

import antono2.memory

struct BlockReservation {
	owner      voidptr
	block_id   u64
	allocation memory.RangeAllocation
pub:
	memory_type u32
	offset      u64
	size        u64
}

struct MemoryBlock {
	id          u64
	memory_type u32
	capacity    u64
	dedicated   bool
	ranges      &memory.RangeAllocator @[required]
}

struct BlockPoolStats {
	block_count      int
	allocation_count int
	committed        u64
	used             u64
	free             u64
}

// MemoryBlockPool plans suballocations without owning Vulkan handles. Keeping
// this layer independent makes allocation policy deterministic and testable on
// systems without a Vulkan device.
struct MemoryBlockPool {
	default_block_size u64
	max_blocks         int
mut:
	blocks  []MemoryBlock
	next_id u64 = 1
}

fn new_memory_block_pool(default_block_size u64, max_blocks int) !&MemoryBlockPool {
	if default_block_size == 0 {
		return error('default block size must be greater than zero')
	}
	if max_blocks <= 0 {
		return error('maximum block count must be greater than zero')
	}
	return &MemoryBlockPool{
		default_block_size: default_block_size
		max_blocks:         max_blocks
	}
}

fn (pool &MemoryBlockPool) block_count() int {
	return pool.blocks.len
}

fn (pool &MemoryBlockPool) block_allocation_count(block_id u64) ?int {
	for block in pool.blocks {
		if block.id == block_id {
			return block.ranges.allocation_count()
		}
	}
	return none
}

fn (pool &MemoryBlockPool) block_is_dedicated(block_id u64) ?bool {
	for block in pool.blocks {
		if block.id == block_id {
			return block.dedicated
		}
	}
	return none
}

fn (pool &MemoryBlockPool) recommended_block_size(requested_size u64) !u64 {
	if requested_size == 0 {
		return error('allocation size must be greater than zero')
	}
	return if requested_size > pool.default_block_size {
		requested_size
	} else {
		pool.default_block_size
	}
}

fn (mut pool MemoryBlockPool) add_block(memory_type u32, capacity u64) !u64 {
	return pool.add_block_with_policy(memory_type, capacity, false)
}

fn (mut pool MemoryBlockPool) add_dedicated_block(memory_type u32, capacity u64) !u64 {
	return pool.add_block_with_policy(memory_type, capacity, true)
}

fn (mut pool MemoryBlockPool) add_block_with_policy(memory_type u32, capacity u64, dedicated bool) !u64 {
	if capacity == 0 {
		return error('memory block capacity must be greater than zero')
	}
	if pool.blocks.len >= pool.max_blocks {
		return error('maximum memory block count reached')
	}
	id := pool.next_block_id()
	pool.blocks << MemoryBlock{
		id:          id
		memory_type: memory_type
		capacity:    capacity
		dedicated:   dedicated
		ranges:      memory.new_range_allocator(capacity)
	}
	return id
}

// reserve searches compatible blocks in creation order. It never creates a
// block, allowing the Vulkan layer to allocate a real VkDeviceMemory object
// before registering its matching planning block.
fn (mut pool MemoryBlockPool) reserve(memory_type u32, size u64, alignment u64) !BlockReservation {
	if size == 0 {
		return error('allocation size must be greater than zero')
	}
	if alignment == 0 {
		return error('allocation alignment must be greater than zero')
	}
	for mut block in pool.blocks {
		if block.memory_type != memory_type || block.dedicated {
			continue
		}
		if allocation := block.ranges.allocate(size, alignment) {
			return BlockReservation{
				owner:       pool
				block_id:    block.id
				allocation:  allocation
				memory_type: memory_type
				offset:      allocation.offset
				size:        allocation.size
			}
		}
	}
	return error('no compatible memory block has a large enough aligned range')
}

fn (mut pool MemoryBlockPool) reserve_from_block(block_id u64, size u64, alignment u64) !BlockReservation {
	if size == 0 {
		return error('allocation size must be greater than zero')
	}
	if alignment == 0 {
		return error('allocation alignment must be greater than zero')
	}
	for mut block in pool.blocks {
		if block.id != block_id {
			continue
		}
		allocation := block.ranges.allocate(size, alignment)!
		return BlockReservation{
			owner:       pool
			block_id:    block.id
			allocation:  allocation
			memory_type: block.memory_type
			offset:      allocation.offset
			size:        allocation.size
		}
	}
	return error('memory block does not exist')
}

fn (pool &MemoryBlockPool) contains(reservation BlockReservation) bool {
	if reservation.owner != voidptr(pool) || reservation.block_id == 0 {
		return false
	}
	for block in pool.blocks {
		if block.id == reservation.block_id {
			return block.memory_type == reservation.memory_type
				&& reservation.offset == reservation.allocation.offset
				&& reservation.size == reservation.allocation.size
				&& block.ranges.contains(reservation.allocation)
		}
	}
	return false
}

fn (mut pool MemoryBlockPool) release(reservation BlockReservation) bool {
	if reservation.owner != voidptr(pool) || reservation.block_id == 0 {
		return false
	}
	for mut block in pool.blocks {
		if block.id != reservation.block_id || block.memory_type != reservation.memory_type {
			continue
		}
		if reservation.offset != reservation.allocation.offset
			|| reservation.size != reservation.allocation.size {
			return false
		}
		return block.ranges.release(reservation.allocation)
	}
	return false
}

// remove_empty_block removes planning metadata only when the block has no live
// suballocations. The caller remains responsible for freeing VkDeviceMemory.
fn (mut pool MemoryBlockPool) remove_empty_block(block_id u64) bool {
	for index, block in pool.blocks {
		if block.id != block_id {
			continue
		}
		if block.ranges.allocation_count() != 0 {
			return false
		}
		pool.blocks.delete(index)
		return true
	}
	return false
}

fn (pool &MemoryBlockPool) stats() BlockPoolStats {
	mut allocation_count := 0
	mut committed := u64(0)
	mut used := u64(0)
	for block in pool.blocks {
		allocation_count += block.ranges.allocation_count()
		committed += block.capacity
		used += block.ranges.used_bytes()
	}
	return BlockPoolStats{
		block_count:      pool.blocks.len
		allocation_count: allocation_count
		committed:        committed
		used:             used
		free:             committed - used
	}
}

fn (mut pool MemoryBlockPool) next_block_id() u64 {
	for {
		id := pool.next_id
		pool.next_id++
		if pool.next_id == 0 {
			pool.next_id = 1
		}
		mut in_use := false
		for block in pool.blocks {
			if block.id == id {
				in_use = true
				break
			}
		}
		if id != 0 && !in_use {
			return id
		}
	}
	return 0
}
