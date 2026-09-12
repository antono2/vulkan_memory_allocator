module main

import antono2.vkmemalloc as vma
import antono2.vulkan as vk

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

fn run() ! {
	require_success(vk.initialize_loader(), 'initialize Vulkan loader')!
	application_info := vk.ApplicationInfo{
		pApplicationName:   c'vkmemalloc image suballocation example'
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
		preferred_block_size: 128 * 1024
	})
	defer {
		allocator.destroy()
	}

	image_info := vk.ImageCreateInfo{
		imageType:     ._2d
		format:        .r8g8b8a8_unorm
		extent:        vk.Extent3D{
			width:  64
			height: 64
			depth:  1
		}
		mipLevels:     1
		arrayLayers:   1
		samples:       ._1
		tiling:        .optimal
		usage:         u32(vk.ImageUsageFlagBits.transfer_src) | u32(vk.ImageUsageFlagBits.transfer_dst)
		sharingMode:   .exclusive
		initialLayout: .undefined
	}
	mut first_image := vk.Image(unsafe { nil })
	mut first_allocation := vma.AllocationInfo{}
	require_success(allocator.create_suballocated_image_with_options(&image_info, vma.AllocationOptions{
		usage: .gpu_only
	}, &first_image, mut first_allocation), 'create first optimal image')!
	defer {
		if !isnil(first_image) {
			vk.destroy_image(device, first_image, unsafe { nil })
		}
		if !isnil(first_allocation.memory) {
			_ = allocator.release(mut first_allocation)
		}
	}

	mut second_image := vk.Image(unsafe { nil })
	mut second_allocation := vma.AllocationInfo{}
	require_success(allocator.create_suballocated_image_with_options(&image_info, vma.AllocationOptions{
		usage: .gpu_only
	}, &second_image, mut second_allocation), 'create second optimal image')!
	defer {
		if !isnil(second_image) {
			vk.destroy_image(device, second_image, unsafe { nil })
		}
		if !isnil(second_allocation.memory) {
			_ = allocator.release(mut second_allocation)
		}
	}

	if first_allocation.memory != second_allocation.memory {
		return error('the driver requested dedicated memory; this smoke test requires shareable images')
	}
	assert first_allocation.resource_class == .optimal_image
	assert second_allocation.resource_class == .optimal_image
	assert first_allocation.offset != second_allocation.offset
	mut first_requirements := vk.MemoryRequirements{}
	mut second_requirements := vk.MemoryRequirements{}
	vk.get_image_memory_requirements(device, first_image, mut first_requirements)
	vk.get_image_memory_requirements(device, second_image, mut second_requirements)
	assert first_allocation.offset % first_requirements.alignment == 0
	assert second_allocation.offset % second_requirements.alignment == 0
	assert second_allocation.offset >= first_allocation.offset + first_allocation.size

	linear_image_info := vk.ImageCreateInfo{
		imageType:     ._2d
		format:        .r8g8b8a8_unorm
		extent:        vk.Extent3D{
			width:  64
			height: 64
			depth:  1
		}
		mipLevels:     1
		arrayLayers:   1
		samples:       ._1
		tiling:        .linear
		usage:         u32(vk.ImageUsageFlagBits.transfer_src) | u32(vk.ImageUsageFlagBits.transfer_dst)
		sharingMode:   .exclusive
		initialLayout: .undefined
	}
	mut linear_image := vk.Image(unsafe { nil })
	mut linear_allocation := vma.AllocationInfo{}
	require_success(allocator.create_suballocated_image_with_options(&linear_image_info, vma.AllocationOptions{
		usage: .gpu_only
	}, &linear_image, mut linear_allocation), 'create linear image')!
	defer {
		if !isnil(linear_image) {
			vk.destroy_image(device, linear_image, unsafe { nil })
		}
		if !isnil(linear_allocation.memory) {
			_ = allocator.release(mut linear_allocation)
		}
	}
	assert linear_allocation.resource_class == .linear_image
	assert linear_allocation.memory != first_allocation.memory

	buffer_info := vk.BufferCreateInfo{
		size:        4096
		usage:       u32(vk.BufferUsageFlagBits.transfer_dst)
		sharingMode: .exclusive
	}
	mut buffer := vk.Buffer(unsafe { nil })
	mut buffer_allocation := vma.AllocationInfo{}
	require_success(allocator.create_buffer_with_options(&buffer_info, vma.AllocationOptions{
		usage: .gpu_only
	}, &buffer, mut buffer_allocation), 'create device buffer')!
	defer {
		if !isnil(buffer) {
			vk.destroy_buffer(device, buffer, unsafe { nil })
		}
		if !isnil(buffer_allocation.memory) {
			_ = allocator.release(mut buffer_allocation)
		}
	}
	assert buffer_allocation.resource_class == .buffer
	assert buffer_allocation.memory != first_allocation.memory

	image_stats := allocator.stats_for_memory_type_and_class(first_allocation.mem_type,
		.optimal_image)
	assert image_stats.block_count == 1
	assert image_stats.allocation_count == 2
	assert image_stats.committed >= image_stats.used
	buffer_stats := allocator.stats_for_memory_type_and_class(buffer_allocation.mem_type, .buffer)
	assert buffer_stats.block_count == 1
	assert buffer_stats.allocation_count == 1
	linear_stats := allocator.stats_for_memory_type_and_class(linear_allocation.mem_type,
		.linear_image)
	assert linear_stats.block_count == 1
	assert linear_stats.allocation_count == 1
	assert allocator.stats().block_count == 3
	assert allocator.stats().allocation_count == 4
	println('two optimal images share one class-safe block; the linear image and buffer use separate blocks')
	println('images: committed=${image_stats.committed}, used=${image_stats.used}, offsets=${first_allocation.offset}/${second_allocation.offset}')

	vk.destroy_buffer(device, buffer, unsafe { nil })
	buffer = vk.Buffer(unsafe { nil })
	assert allocator.release(mut buffer_allocation)
	vk.destroy_image(device, linear_image, unsafe { nil })
	linear_image = vk.Image(unsafe { nil })
	assert allocator.release(mut linear_allocation)
	vk.destroy_image(device, second_image, unsafe { nil })
	second_image = vk.Image(unsafe { nil })
	assert allocator.release(mut second_allocation)
	vk.destroy_image(device, first_image, unsafe { nil })
	first_image = vk.Image(unsafe { nil })
	assert allocator.release(mut first_allocation)
	assert allocator.trim_empty_blocks() == 3
	assert allocator.stats() == vma.AllocatorStats{}
}

fn main() {
	run() or { panic(err) }
}
