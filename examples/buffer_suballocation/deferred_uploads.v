// Uses memory v1.5's bounded completion queue with actual Vulkan fences.
// Exercises real ordered queue submissions, fence observation and host readback.
module main

import antono2.memory
import antono2.vkmemalloc as vma
import antono2.vulkan as vk

fn record_upload(command vk.CommandBuffer, source vk.Buffer, destination vk.Buffer, slice vma.UploadSlice, offset u64) ! {
	begin := vk.CommandBufferBeginInfo{
		flags: u32(vk.CommandBufferUsageFlagBits.one_time_submit)
	}
	require_success(vk.begin_command_buffer(command, &begin), 'begin deferred copy')!
	region := vk.BufferCopy{
		srcOffset: slice.offset
		dstOffset: offset
		size:      4
	}
	vk.cmd_copy_buffer(command, source, destination, 1, &region)
	barrier := vk.BufferMemoryBarrier{
		srcAccessMask:       u32(vk.AccessFlagBits.transfer_write)
		dstAccessMask:       u32(vk.AccessFlagBits.host_read)
		srcQueueFamilyIndex: vk.queue_family_ignored
		dstQueueFamilyIndex: vk.queue_family_ignored
		buffer:              destination
		offset:              offset
		size:                4
	}
	vk.cmd_pipeline_barrier(command, u32(vk.PipelineStageFlagBits.transfer),
		u32(vk.PipelineStageFlagBits.host), 0, 0, unsafe { nil }, 1, &barrier, 0, unsafe { nil })
	require_success(vk.end_command_buffer(command), 'end deferred copy')!
}

fn submit_copy(queue vk.Queue, command vk.CommandBuffer, fence vk.Fence) ! {
	submit := vk.SubmitInfo{
		commandBufferCount: 1
		pCommandBuffers:    &command
	}
	require_success(vk.queue_submit(queue, 1, &submit, fence), 'submit deferred copy')!
}

fn retire_completed(mut pending memory.RetirementQueue[vma.UploadSlice], mut uploads vma.UploadRing) int {
	mut retired := 0
	for {
		slice := pending.try_take_ready() or { break }
		if !uploads.retire(slice) { panic('upload FIFO retirement failed') }
		retired++
	}
	return retired
}

fn run_deferred_uploads(device vk.Device, family u32, mut allocator vma.Allocator) ! {
	mut queue := vk.Queue(unsafe { nil })
	vk.get_device_queue(device, family, 0, &queue)
	pool_info := vk.CommandPoolCreateInfo{
		queueFamilyIndex: family
	}
	mut command_pool := vk.CommandPool(unsafe { nil })
	require_success(vk.create_command_pool(device, &pool_info, unsafe { nil }, &command_pool),
		'create copy pool')!
	defer { vk.destroy_command_pool(device, command_pool, unsafe { nil }) }
	mut commands := unsafe { []vk.CommandBuffer{len: 3} }
	allocate_info := vk.CommandBufferAllocateInfo{
		commandPool:        command_pool
		level:              .primary
		commandBufferCount: 3
	}
	require_success(vk.allocate_command_buffers(device, &allocate_info, commands.data),
		'allocate copy commands')!
	mut fences := []vk.Fence{len: 3, init: vk.Fence(unsafe { nil })}
	defer {
		for fence in fences {
			if !isnil(fence) { vk.destroy_fence(device, fence, unsafe { nil }) }
		}
	}
	for index in 0 .. fences.len {
		info := vk.FenceCreateInfo{}
		mut fence := vk.Fence(unsafe { nil })
		require_success(vk.create_fence(device, &info, unsafe { nil }, &fence), 'create copy fence')!
		fences[index] = fence
	}
	buffer_info := vk.BufferCreateInfo{
		size:        16
		usage:       u32(vk.BufferUsageFlagBits.transfer_dst)
		sharingMode: .exclusive
	}
	mut destination := vk.Buffer(unsafe { nil })
	mut destination_allocation := vma.AllocationInfo{}
	require_success(allocator.create_buffer_with_options(&buffer_info, vma.AllocationOptions{
		usage: .readback
	}, &destination, mut destination_allocation), 'create readback destination')!
	defer {
		vk.destroy_buffer(device, destination, unsafe { nil })
		_ = allocator.release(mut destination_allocation)
	}
	mut uploads := vma.new_upload_ring_with_options(mut allocator, 1024, vma.AllocationOptions{
		usage: .upload
	})!
	mut pending := memory.new_retirement_queue[vma.UploadSlice](2)!
	defer {
		// This runs before buffer/fence/command cleanup, including on error paths.
		idle := vk.device_wait_idle(device)
		if idle == .success {
			pending.advance_completed(~u64(0)) or { panic(err) }
			_ = retire_completed(mut pending, mut uploads)
			_ = uploads.destroy()
		} else {
			// A lost device is not completion evidence. Destroy the API object as
			// part of device teardown without falsely reporting completed tokens.
			vk.destroy_buffer(device, uploads.buffer, unsafe { nil })
		}
	}
	for index in 0 .. 2 {
		if pending.is_full() {
			return error('unexpected queue backpressure')
		}
		slice := uploads.allocate(400, 16)!
		pending.enqueue(slice, u64(index + 1))!
		unsafe {
			*(&u32(slice.data)) = u32(21 + index)
		}
		require_success(uploads.flush(slice), 'flush queued upload')!
		record_upload(commands[index], uploads.buffer, destination, slice, u64(index * 4))!
		submit_copy(queue, commands[index], fences[index])!
	}
	// No reuse before the application observes completion, even if the GPU has
	// already finished. A full queue must not cause another ring allocation.
	if pending.try_take_ready() != none {
		return error('premature retirement')
	}
	if !pending.is_full() {
		return error('expected bounded queue exhaustion')
	}
	before := uploads.stats()
	if _ := pending.enqueue(vma.UploadSlice{}, 3) {
		return error('expected backpressure')
	}
	if uploads.stats() != before {
		return error('backpressure changed upload allocation state')
	}
	first_fence := fences[0]
	require_success(vk.wait_for_fences(device, 1, &first_fence, vk._true, 10_000_000_000),
		'wait first copy')!
	pending.advance_completed(1)!
	if retire_completed(mut pending, mut uploads) != 1 {
		return error('expected first retirement only')
	}
	wrapped := uploads.allocate(300, 16)!
	pending.enqueue(wrapped, 3)!
	if wrapped.offset != 0 {
		return error('expected upload wraparound')
	}
	unsafe {
		*(&u32(wrapped.data)) = 23
	}
	require_success(uploads.flush(wrapped), 'flush wrapped queued upload')!
	record_upload(commands[2], uploads.buffer, destination, wrapped, 8)!
	submit_copy(queue, commands[2], fences[2])!
	// One queue executes these submissions in order. The final fence covers all
	// three copies and their transfer-to-host barriers; unrelated queues would
	// require separate completion domains or explicit synchronization.
	last_fence := fences[2]
	require_success(vk.wait_for_fences(device, 1, &last_fence, vk._true, 10_000_000_000),
		'wait final copy')!
	pending.advance_completed(3)!
	if retire_completed(mut pending, mut uploads) != 2 {
		return error('expected final two retirements')
	}
	mut mapped := voidptr(unsafe { nil })
	require_success(allocator.map(mut destination_allocation, &mapped), 'map copy readback')!
	defer { allocator.unmap(mut destination_allocation) }
	require_success(allocator.invalidate(destination_allocation), 'invalidate copy readback')!
	for index in 0 .. 3 {
		actual := unsafe { *(&u32(usize(mapped) + usize(index * 4))) }
		if actual != u32(21 + index) {
			return error('independent copy readback mismatch at ${index}: ${actual}')
		}
	}
	if !pending.is_empty() || uploads.stats().allocation_count != 0 {
		return error('pending work at shutdown')
	}
	println('fenced retirement: copies=3 readback=21,22,23 wrap=0 pending=0')
}
