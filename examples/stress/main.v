module main

import antono2.vkmemalloc as vma
import antono2.vulkan as vk

const churn_cycles = 64
const churn_batch_size = 16

fn require_success(result vk.Result, operation string) ! {
	if result != .success {
		return error('${operation} failed: ${result}')
	}
}

fn first_physical_device(instance vk.Instance) !vk.PhysicalDevice {
	mut count := u32(0)
	require_success(vk.enumerate_physical_devices(instance, &count, unsafe { nil }),
		'enumerate physical device count')!
	if count == 0 {
		return error('no Vulkan physical device is available')
	}
	mut devices := unsafe { []vk.PhysicalDevice{len: int(count)} }
	require_success(vk.enumerate_physical_devices(instance, &count, devices.data),
		'enumerate physical devices')!
	return devices[0]
}

fn create_upload_buffer(mut allocator vma.Allocator, size u64) !(vk.Buffer, vma.AllocationInfo) {
	buffer_info := vk.BufferCreateInfo{
		size:        size
		usage:       u32(vk.BufferUsageFlagBits.transfer_src)
		sharingMode: .exclusive
	}
	mut buffer := vk.Buffer(unsafe { nil })
	mut allocation := vma.AllocationInfo{}
	require_success(allocator.create_buffer_with_options(&buffer_info, vma.AllocationOptions{
		usage: .upload
	}, &buffer, mut allocation), 'create upload buffer')!
	return buffer, allocation
}

fn run() ! {
	require_success(vk.initialize_loader(), 'initialize Vulkan loader')!
	application_info := vk.ApplicationInfo{
		pApplicationName:   c'vkmemalloc sustained allocation workload'
		applicationVersion: 1
		pEngineName:        c'none'
		apiVersion:         vk.api_version_1_1
	}
	instance_info := vk.InstanceCreateInfo{
		pApplicationInfo: &application_info
	}
	mut instance := vk.Instance(unsafe { nil })
	require_success(vk.create_instance(&instance_info, unsafe { nil }, &instance),
		'create Vulkan instance')!
	defer {
		vk.destroy_instance(instance, unsafe { nil })
	}
	vk.load_instance_commands(instance)

	physical_device := first_physical_device(instance)!
	mut priority := f32(1)
	queue_info := vk.DeviceQueueCreateInfo{
		queueFamilyIndex: 0
		queueCount:       1
		pQueuePriorities: &priority
	}
	device_info := vk.DeviceCreateInfo{
		queueCreateInfoCount: 1
		pQueueCreateInfos:    &queue_info
	}
	mut device := vk.Device(unsafe { nil })
	require_success(vk.create_device(physical_device, &device_info, unsafe { nil }, &device),
		'create Vulkan device')!
	defer {
		vk.destroy_device(device, unsafe { nil })
	}
	vk.load_device_commands(device)

	mut allocator := vma.new(vma.AllocatorCreateInfo{
		physical_device:      physical_device
		device:               device
		preferred_block_size: 4096
		event_trace_capacity: 64
	})
	defer {
		allocator.destroy()
	}

	for cycle in 0 .. churn_cycles {
		mut buffers := []vk.Buffer{len: churn_batch_size, init: vk.Buffer(unsafe { nil })}
		mut allocations := []vma.AllocationInfo{len: churn_batch_size}
		for index in 0 .. churn_batch_size {
			buffer, allocation := create_upload_buffer(mut allocator, u64(64 +
				(cycle * 29 + index * 47) % 769))!
			buffers[index] = buffer
			allocations[index] = allocation
			mut mapped := voidptr(unsafe { nil })
			require_success(allocator.map(mut allocations[index], &mapped), 'map upload buffer')!
			unsafe {
				*(&u8(mapped)) = u8((cycle + index) & 0xff)
			}
			require_success(allocator.flush_range(allocations[index], 0, 1), 'flush upload buffer')!
			allocator.unmap(mut allocations[index])
		}

		// Create holes, refill them with different sizes, then release everything.
		for index in 0 .. churn_batch_size {
			if index % 2 == 0 {
				vk.destroy_buffer(device, buffers[index], unsafe { nil })
				assert allocator.release(mut allocations[index])
			}
		}
		mut refill_buffers := []vk.Buffer{len: churn_batch_size / 2, init: vk.Buffer(unsafe { nil })}
		mut refill_allocations := []vma.AllocationInfo{len: churn_batch_size / 2}
		for index in 0 .. refill_buffers.len {
			buffer, allocation := create_upload_buffer(mut allocator, u64(96 +
				(cycle * 17 + index * 61) % 641))!
			refill_buffers[index] = buffer
			refill_allocations[index] = allocation
		}
		for index in 0 .. churn_batch_size {
			if index % 2 != 0 {
				vk.destroy_buffer(device, buffers[index], unsafe { nil })
				assert allocator.release(mut allocations[index])
			}
		}
		for index in 0 .. refill_buffers.len {
			vk.destroy_buffer(device, refill_buffers[index], unsafe { nil })
			assert allocator.release(mut refill_allocations[index])
		}
		assert allocator.stats().allocation_count == 0
	}

	diagnostics := allocator.diagnostics()
	expected_allocations := u64(churn_cycles * (churn_batch_size + churn_batch_size / 2))
	assert diagnostics.current.allocation_count == 0
	assert diagnostics.counters.allocation_attempts == expected_allocations
	assert diagnostics.counters.allocation_successes == expected_allocations
	assert diagnostics.counters.allocation_failures == 0
	assert diagnostics.counters.allocation_releases == expected_allocations
	assert diagnostics.counters.block_allocations > 0
	assert diagnostics.counters.block_reuses > 1_000
	assert diagnostics.counters.block_allocations + diagnostics.counters.block_reuses == diagnostics.counters.allocation_successes
	assert diagnostics.counters.peak_allocation_count >= churn_batch_size
	assert diagnostics.retained_event_count == 64
	assert diagnostics.dropped_event_count > 0
	events := allocator.recent_events()
	assert events.len == 64
	assert events[0].sequence < events[events.len - 1].sequence
	trimmed := allocator.trim_empty_blocks()
	assert trimmed > 0
	assert allocator.diagnostics().counters.trimmed_blocks == u64(trimmed)
	assert allocator.stats().block_count == 0
	println('sustained churn passed: ${expected_allocations} allocations, ${diagnostics.counters.block_reuses} block reuses, peak live=${diagnostics.counters.peak_allocation_count}')
}

fn main() {
	run() or { panic(err) }
}
