module vkmemalloc

fn assert_block_pool_invariants(pool &MemoryBlockPool, active []BlockReservation, committed u64) {
	stats := pool.stats()
	assert stats.block_count == 6
	assert stats.allocation_count == active.len
	assert stats.committed == committed
	assert stats.used + stats.free == committed
	assert stats.largest_free_range <= stats.free
	mut used := u64(0)
	for index, reservation in active {
		assert pool.contains(reservation)
		used += reservation.size
		for other in active[index + 1..] {
			if reservation.block_id == other.block_id {
				assert reservation.offset + reservation.size <= other.offset
					|| other.offset + other.size <= reservation.offset
			}
		}
	}
	assert stats.used == used
	type_0 := pool.stats_for_memory_type(0)
	type_1 := pool.stats_for_memory_type(1)
	assert type_0.block_count == 3
	assert type_1.block_count == 3
	assert type_0.allocation_count + type_1.allocation_count == active.len
	assert type_0.committed + type_1.committed == committed
	assert type_0.used + type_1.used == used
	mut class_allocations := 0
	mut class_committed := u64(0)
	mut class_used := u64(0)
	for resource_class in [ResourceClass.buffer, .linear_image, .optimal_image] {
		class_stats := pool.stats_for_resource_class(resource_class)
		assert class_stats.block_count == 2
		class_allocations += class_stats.allocation_count
		class_committed += class_stats.committed
		class_used += class_stats.used
	}
	assert class_allocations == active.len
	assert class_committed == committed
	assert class_used == used
}

fn test_block_pool_sustained_mixed_workload() {
	block_size := u64(4096)
	mut pool := new_memory_block_pool(block_size, 6) or { panic(err) }
	resource_classes := [ResourceClass.buffer, .linear_image, .optimal_image]
	for memory_type in u32(0) .. 2 {
		for resource_class in resource_classes {
			_ = pool.add_block_for_class(memory_type, resource_class, block_size) or { panic(err) }
		}
	}
	committed := block_size * 6
	alignments := [u64(1), 2, 3, 4, 8, 16, 31, 64, 128, 256]
	mut active := []BlockReservation{}
	mut state := u32(0xa110ca7e)
	mut successful_allocations := 0

	for step in 0 .. 30_000 {
		state = state * 1_664_525 + 1_013_904_223
		if active.len > 0 && state % 3 == 0 {
			index := int((state >> 8) % u32(active.len))
			assert pool.release(active[index])
			active.delete(index)
		} else {
			memory_type := (state >> 4) & 1
			resource_class := resource_classes[int((state >> 6) % u32(resource_classes.len))]
			size := u64(1 + (state >> 12) % 257)
			alignment := alignments[int((state >> 24) % u32(alignments.len))]
			if reservation := pool.reserve_for_class(memory_type, resource_class, size, alignment) {
				assert reservation.offset % alignment == 0
				assert reservation.resource_class == resource_class
				active << reservation
				successful_allocations++
			} else if active.len > 0 {
				index := int((state >> 8) % u32(active.len))
				assert pool.release(active[index])
				active.delete(index)
			}
		}
		if step % 200 == 0 {
			assert_block_pool_invariants(pool, active, committed)
		}
	}

	assert successful_allocations > 5_000
	for reservation in active {
		assert pool.release(reservation)
	}
	assert_block_pool_invariants(pool, [], committed)
	final_stats := pool.stats()
	assert final_stats.used == 0
	assert final_stats.free_range_count == 6
	assert final_stats.largest_free_range == block_size
	assert final_stats.empty_block_count == 6
}
