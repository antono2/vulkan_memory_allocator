module vkmemalloc

fn test_block_pool_validates_configuration() {
	if _ := new_memory_block_pool(0, 1) {
		assert false, 'zero block size must fail'
	} else {
		assert err.msg().contains('block size')
	}
	if _ := new_memory_block_pool(1024, 0) {
		assert false, 'zero block count must fail'
	} else {
		assert err.msg().contains('block count')
	}
}

fn test_block_pool_recommends_default_or_dedicated_size() {
	pool := new_memory_block_pool(1024, 4) or { panic(err) }
	assert pool.recommended_block_size(128) or { panic(err) } == 1024
	assert pool.recommended_block_size(2048) or { panic(err) } == 2048
}

fn test_block_pool_suballocates_by_memory_type_and_alignment() {
	mut pool := new_memory_block_pool(64, 4) or { panic(err) }
	device_block := pool.add_block(2, 64) or { panic(err) }
	_ = pool.add_block(1, 64) or { panic(err) }

	first := pool.reserve(2, 13, 1) or { panic(err) }
	second := pool.reserve(2, 16, 16) or { panic(err) }
	staging := pool.reserve(1, 8, 8) or { panic(err) }

	assert first.block_id == device_block
	assert first.offset == 0
	assert second.offset == 16
	assert staging.memory_type == 1
	assert pool.contains(first)
	assert pool.contains(second)
	assert pool.contains(staging)

	stats := pool.stats()
	assert stats.block_count == 2
	assert stats.allocation_count == 3
	assert stats.committed == 128
	assert stats.used == 37
	assert stats.free == 91
}

fn test_block_pool_reports_exhaustion_without_mutation() {
	mut pool := new_memory_block_pool(16, 1) or { panic(err) }
	_ = pool.add_block(0, 16) or { panic(err) }
	_ = pool.reserve(0, 12, 1) or { panic(err) }
	before := pool.stats()

	if _ := pool.reserve(0, 8, 1) {
		assert false, 'oversized free range request must fail'
	} else {
		assert err.msg().contains('aligned range')
	}
	assert pool.stats() == before
	if _ := pool.add_block(0, 16) {
		assert false, 'block limit must fail'
	} else {
		assert err.msg().contains('maximum')
	}
}

fn test_block_pool_never_reuses_dedicated_blocks() {
	mut pool := new_memory_block_pool(64, 2) or { panic(err) }
	dedicated_id := pool.add_dedicated_block(2, 64) or { panic(err) }
	dedicated := pool.reserve_from_block(dedicated_id, 32, 16) or { panic(err) }

	if _ := pool.reserve(2, 16, 1) {
		assert false, 'shared allocation must not reuse a dedicated block'
	} else {
		assert err.msg().contains('compatible memory block')
	}
	assert pool.contains(dedicated)
}

fn test_block_pool_release_coalesces_and_allows_empty_removal() {
	mut pool := new_memory_block_pool(32, 2) or { panic(err) }
	block_id := pool.add_block(3, 32) or { panic(err) }
	first := pool.reserve_from_block(block_id, 8, 1) or { panic(err) }
	second := pool.reserve_from_block(block_id, 8, 1) or { panic(err) }

	assert !pool.remove_empty_block(block_id)
	first_released := pool.release(first)
	assert first_released
	assert !pool.remove_empty_block(block_id)
	second_released := pool.release(second)
	assert second_released
	assert pool.remove_empty_block(block_id)
	assert pool.block_count() == 0
	assert pool.stats().committed == 0
}

fn test_block_pool_rejects_foreign_forged_and_stale_reservations() {
	mut first_pool := new_memory_block_pool(32, 2) or { panic(err) }
	mut second_pool := new_memory_block_pool(32, 2) or { panic(err) }
	first_block := first_pool.add_block(0, 32) or { panic(err) }
	_ = second_pool.add_block(0, 32) or { panic(err) }
	reservation := first_pool.reserve(0, 8, 1) or { panic(err) }
	foreign := second_pool.reserve(0, 8, 1) or { panic(err) }

	assert !first_pool.contains(foreign)
	assert !first_pool.release(foreign)
	assert !first_pool.release(BlockReservation{
		owner:       reservation.owner
		block_id:    reservation.block_id
		allocation:  reservation.allocation
		memory_type: reservation.memory_type
		offset:      reservation.offset + 1
		size:        reservation.size
	})
	released := first_pool.release(reservation)
	assert released
	assert !first_pool.contains(reservation)
	assert !first_pool.release(reservation)
	assert first_pool.remove_empty_block(first_block)
}

fn test_block_pool_reuses_coalesced_space_deterministically() {
	mut pool := new_memory_block_pool(256, 1) or { panic(err) }
	_ = pool.add_block(5, 256) or { panic(err) }
	mut active := []BlockReservation{}

	for _ in 0 .. 2_000 {
		if reservation := pool.reserve(5, 16, 16) {
			active << reservation
		} else {
			released := pool.release(active[0])
			assert released
			active.delete(0)
		}
	}
	for reservation in active {
		released := pool.release(reservation)
		assert released
	}
	stats := pool.stats()
	assert stats.allocation_count == 0
	assert stats.used == 0
	assert stats.free == 256
}
