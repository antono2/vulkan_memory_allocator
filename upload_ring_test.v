module vkmemalloc

import antono2.memory

fn test_upload_ring_returns_aligned_host_pointers_and_wraps() {
	mut storage := []u8{len: 64}
	mut uploads := UploadRing{
		capacity: 64
		mapped: storage.data
		ranges: memory.new_ring_allocator(64)
	}
	first := uploads.allocate(24, 16) or { panic(err) }
	second := uploads.allocate(24, 16) or { panic(err) }
	assert first.offset == 0
	assert second.offset == 32
	assert first.data == storage.data
	assert second.data == unsafe { voidptr(usize(storage.data) + 32) }
	assert uploads.contains(first)
	assert uploads.contains(second)

	first_retired := uploads.retire(first)
	assert first_retired
	wrapped := uploads.allocate(16, 16) or { panic(err) }
	assert wrapped.offset == 0
	assert wrapped.data == storage.data
	assert !uploads.retire(wrapped)
	second_retired := uploads.retire(second)
	assert second_retired
	wrapped_retired := uploads.retire(wrapped)
	assert wrapped_retired
	assert uploads.stats().free == 64
}

fn test_upload_ring_rejects_foreign_forged_and_destroyed_slices() {
	mut first_storage := []u8{len: 32}
	mut second_storage := []u8{len: 32}
	mut first_ring := UploadRing{
		capacity: 32
		mapped: first_storage.data
		ranges: memory.new_ring_allocator(32)
	}
	mut second_ring := UploadRing{
		capacity: 32
		mapped: second_storage.data
		ranges: memory.new_ring_allocator(32)
	}
	allocation := first_ring.allocate(8, 1) or { panic(err) }
	foreign := second_ring.allocate(8, 1) or { panic(err) }
	assert !first_ring.contains(foreign)
	assert !first_ring.retire(foreign)
	forged := UploadSlice{
		owner: allocation.owner
		allocation: allocation.allocation
		offset: allocation.offset
		size: allocation.size
		data: unsafe { voidptr(usize(allocation.data) + 1) }
	}
	assert !first_ring.contains(forged)
	assert !first_ring.retire(forged)

	first_ring.destroyed = true
	assert !first_ring.contains(allocation)
	if _ := first_ring.allocate(1, 1) {
		assert false, 'destroyed upload ring must reject allocation'
	} else {
		assert err.msg().contains('destroyed')
	}
}
