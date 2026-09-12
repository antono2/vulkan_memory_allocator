module vkmemalloc

import antono2.vulkan as vk

// AllocatorEventKind identifies a high-signal allocator lifecycle event.
pub enum AllocatorEventKind {
	allocation_succeeded
	allocation_failed
	allocation_released
	block_trimmed
}

// AllocatorEvent is one entry in the optional bounded diagnostic trace.
// Sequence numbers are monotonic for the lifetime of the allocator. A memory
// type or heap index of max_u32 means that no compatible choice was available.
pub struct AllocatorEvent {
pub:
	sequence          u64
	kind              AllocatorEventKind
	result            vk.Result
	memory_type       u32 = max_u32
	heap_index        u32 = max_u32
	resource_class    ResourceClass
	requested_size    u64
	allocation_offset u64
	block_size        u64
	created_block     bool
	dedicated         bool
}

// AllocatorCounters contains cumulative activity and high-water marks. The
// current allocator state remains available through AllocatorStats.
pub struct AllocatorCounters {
pub:
	allocation_attempts   u64
	allocation_successes  u64
	allocation_failures   u64
	allocation_releases   u64
	requested_bytes       u64
	successful_bytes      u64
	memory_type_attempts  u64
	fallback_attempts     u64
	trim_retry_attempts   u64
	block_allocations     u64
	block_reuses          u64
	block_frees           u64
	trimmed_blocks        u64
	peak_allocation_count int
	peak_committed        u64
	peak_used             u64
}

struct AllocatorCounterState {
mut:
	allocation_attempts   u64
	allocation_successes  u64
	allocation_failures   u64
	allocation_releases   u64
	requested_bytes       u64
	successful_bytes      u64
	memory_type_attempts  u64
	fallback_attempts     u64
	trim_retry_attempts   u64
	block_allocations     u64
	block_reuses          u64
	block_frees           u64
	trimmed_blocks        u64
	peak_allocation_count int
	peak_committed        u64
	peak_used             u64
}

fn (c &AllocatorCounterState) snapshot() AllocatorCounters {
	return AllocatorCounters{
		allocation_attempts:   c.allocation_attempts
		allocation_successes:  c.allocation_successes
		allocation_failures:   c.allocation_failures
		allocation_releases:   c.allocation_releases
		requested_bytes:       c.requested_bytes
		successful_bytes:      c.successful_bytes
		memory_type_attempts:  c.memory_type_attempts
		fallback_attempts:     c.fallback_attempts
		trim_retry_attempts:   c.trim_retry_attempts
		block_allocations:     c.block_allocations
		block_reuses:          c.block_reuses
		block_frees:           c.block_frees
		trimmed_blocks:        c.trimmed_blocks
		peak_allocation_count: c.peak_allocation_count
		peak_committed:        c.peak_committed
		peak_used:             c.peak_used
	}
}

// AllocatorDiagnostics combines the allocator's current state with cumulative
// counters and trace retention information.
pub struct AllocatorDiagnostics {
pub:
	current              AllocatorStats
	counters             AllocatorCounters
	trace_capacity       int
	retained_event_count int
	dropped_event_count  u64
}

fn (mut a Allocator) next_diagnostic_sequence() u64 {
	sequence := a.next_event_sequence
	a.next_event_sequence++
	if a.next_event_sequence == 0 {
		a.next_event_sequence = 1
	}
	return sequence
}

fn (mut a Allocator) record_event(event AllocatorEvent) {
	if a.event_trace_capacity <= 0 {
		return
	}
	entry := AllocatorEvent{
		...event
		sequence: a.next_diagnostic_sequence()
	}
	if a.events.len < a.event_trace_capacity {
		a.events << entry
		if a.events.len == a.event_trace_capacity {
			a.event_cursor = 0
		}
		return
	}
	a.events[a.event_cursor] = entry
	a.event_cursor = (a.event_cursor + 1) % a.event_trace_capacity
	a.dropped_event_count++
}

fn (mut a Allocator) begin_allocation(requested_size u64) {
	a.counters_.allocation_attempts++
	a.counters_.requested_bytes += requested_size
}

fn (mut a Allocator) note_memory_type_attempt(fallback bool) {
	a.counters_.memory_type_attempts++
	if fallback {
		a.counters_.fallback_attempts++
	}
}

fn (mut a Allocator) note_allocation_success(alloc_info AllocationInfo, dedicated bool) {
	a.counters_.allocation_successes++
	a.counters_.successful_bytes += alloc_info.size
	a.diagnostic_live_count++
	a.diagnostic_live_used += alloc_info.size
	if alloc_info.created_block {
		a.diagnostic_committed += alloc_info.block_size
	}
	if a.diagnostic_live_count > a.counters_.peak_allocation_count {
		a.counters_.peak_allocation_count = a.diagnostic_live_count
	}
	if a.diagnostic_committed > a.counters_.peak_committed {
		a.counters_.peak_committed = a.diagnostic_committed
	}
	if a.diagnostic_live_used > a.counters_.peak_used {
		a.counters_.peak_used = a.diagnostic_live_used
	}
	a.record_event(AllocatorEvent{
		kind:              .allocation_succeeded
		result:            .success
		memory_type:       alloc_info.mem_type
		heap_index:        alloc_info.heap_index
		resource_class:    alloc_info.resource_class
		requested_size:    alloc_info.size
		allocation_offset: alloc_info.offset
		block_size:        alloc_info.block_size
		created_block:     alloc_info.created_block
		dedicated:         dedicated
	})
}

fn (mut a Allocator) note_allocation_failure(result vk.Result, requested_size u64, memory_type u32, heap_index u32, dedicated bool, resource_class ResourceClass) {
	a.counters_.allocation_failures++
	a.record_event(AllocatorEvent{
		kind:           .allocation_failed
		result:         result
		memory_type:    memory_type
		heap_index:     heap_index
		resource_class: resource_class
		requested_size: requested_size
		dedicated:      dedicated
	})
}

fn (mut a Allocator) note_allocation_release(alloc_info AllocationInfo, dedicated bool) {
	a.counters_.allocation_releases++
	if a.diagnostic_live_count > 0 {
		a.diagnostic_live_count--
	}
	if alloc_info.size <= a.diagnostic_live_used {
		a.diagnostic_live_used -= alloc_info.size
	}
	if dedicated && alloc_info.block_size <= a.diagnostic_committed {
		a.diagnostic_committed -= alloc_info.block_size
	}
	a.record_event(AllocatorEvent{
		kind:              .allocation_released
		result:            .success
		memory_type:       alloc_info.mem_type
		heap_index:        alloc_info.heap_index
		resource_class:    alloc_info.resource_class
		requested_size:    alloc_info.size
		allocation_offset: alloc_info.offset
		block_size:        alloc_info.block_size
		created_block:     alloc_info.created_block
		dedicated:         dedicated
	})
}

fn (mut a Allocator) note_block_trimmed(memory_type u32, heap_index u32, resource_class ResourceClass, block_size u64) {
	a.counters_.block_frees++
	a.counters_.trimmed_blocks++
	if block_size <= a.diagnostic_committed {
		a.diagnostic_committed -= block_size
	}
	a.record_event(AllocatorEvent{
		kind:           .block_trimmed
		result:         .success
		memory_type:    memory_type
		heap_index:     heap_index
		resource_class: resource_class
		block_size:     block_size
	})
}

// diagnostics returns a consistent single-threaded snapshot of current state,
// lifetime counters, and bounded-trace retention. Like the allocator itself,
// callers must externally synchronize this query with concurrent mutations.
pub fn (a &Allocator) diagnostics() AllocatorDiagnostics {
	return AllocatorDiagnostics{
		current:              a.stats()
		counters:             a.counters_.snapshot()
		trace_capacity:       a.event_trace_capacity
		retained_event_count: a.events.len
		dropped_event_count:  a.dropped_event_count
	}
}

// recent_events returns retained events in chronological order. Tracing is
// disabled by default and enabled with AllocatorCreateInfo.event_trace_capacity.
pub fn (a &Allocator) recent_events() []AllocatorEvent {
	if a.events.len == 0 {
		return []AllocatorEvent{}
	}
	if a.events.len < a.event_trace_capacity || a.event_cursor == 0 {
		return a.events.clone()
	}
	mut ordered := []AllocatorEvent{cap: a.events.len}
	ordered << a.events[a.event_cursor..]
	ordered << a.events[..a.event_cursor]
	return ordered
}

// reset_diagnostics starts a new measurement window. It clears the event trace
// and cumulative activity while seeding peaks from currently live allocations.
pub fn (mut a Allocator) reset_diagnostics() {
	a.counters_ = AllocatorCounterState{}
	current := a.stats()
	a.counters_.peak_allocation_count = current.allocation_count
	a.counters_.peak_committed = current.committed
	a.counters_.peak_used = current.used
	a.diagnostic_live_count = current.allocation_count
	a.diagnostic_committed = current.committed
	a.diagnostic_live_used = current.used
	a.events.clear()
	a.event_cursor = 0
	a.dropped_event_count = 0
}
