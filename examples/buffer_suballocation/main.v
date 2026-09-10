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
		pApplicationName:   c'vkmemalloc suballocation example'
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
	})
	defer {
		allocator.destroy()
	}

	buffer_info := vk.BufferCreateInfo{
		size:        512
		usage:       u32(vk.BufferUsageFlagBits.transfer_src)
		sharingMode: .exclusive
	}
	mut first_buffer := vk.Buffer(unsafe { nil })
	mut first_allocation := vma.AllocationInfo{}
	require_success(allocator.create_buffer(&buffer_info, .staging, &first_buffer, mut
		first_allocation), 'create first staging buffer')!
	defer {
		if !isnil(first_buffer) {
			vk.destroy_buffer(device, first_buffer, unsafe { nil })
		}
		if !isnil(first_allocation.memory) {
			_ = allocator.release(mut first_allocation)
		}
	}

	mut second_buffer := vk.Buffer(unsafe { nil })
	mut second_allocation := vma.AllocationInfo{}
	require_success(allocator.create_buffer(&buffer_info, .staging, &second_buffer, mut
		second_allocation), 'create second staging buffer')!
	defer {
		if !isnil(second_buffer) {
			vk.destroy_buffer(device, second_buffer, unsafe { nil })
		}
		if !isnil(second_allocation.memory) {
			_ = allocator.release(mut second_allocation)
		}
	}

	assert first_allocation.memory == second_allocation.memory
	assert first_allocation.offset != second_allocation.offset
	stats := allocator.stats()
	assert stats.block_count == 1
	assert stats.allocation_count == 2
	println('two buffers share one block: committed=${stats.committed}, used=${stats.used}')
	mut mapped := voidptr(unsafe { nil })
	require_success(allocator.map(mut second_allocation, &mapped), 'map second staging buffer')!
	unsafe {
		*(&u8(mapped)) = 42
	}
	allocator.unmap(mut second_allocation)

	image_info := vk.ImageCreateInfo{
		imageType:     ._2d
		format:        .r8g8b8a8_unorm
		extent:        vk.Extent3D{
			width:  16
			height: 16
			depth:  1
		}
		mipLevels:     1
		arrayLayers:   1
		samples:       ._1
		tiling:        .optimal
		usage:         u32(vk.ImageUsageFlagBits.transfer_dst)
		sharingMode:   .exclusive
		initialLayout: .undefined
	}
	mut image := vk.Image(unsafe { nil })
	mut image_allocation := vma.AllocationInfo{}
	require_success(allocator.create_image(&image_info, .gpu, &image, mut image_allocation),
		'create dedicated image')!
	defer {
		if !isnil(image) {
			vk.destroy_image(device, image, unsafe { nil })
		}
		if !isnil(image_allocation.memory) {
			_ = allocator.release(mut image_allocation)
		}
	}
	assert image_allocation.memory != first_allocation.memory
	assert image_allocation.offset == 0
	assert allocator.stats().block_count == 2
	println('optimal image uses an isolated dedicated block')

	vk.destroy_image(device, image, unsafe { nil })
	image = vk.Image(unsafe { nil })
	image_released := allocator.release(mut image_allocation)
	assert image_released

	vk.destroy_buffer(device, first_buffer, unsafe { nil })
	first_buffer = vk.Buffer(unsafe { nil })
	first_released := allocator.release(mut first_allocation)
	assert first_released
	vk.destroy_buffer(device, second_buffer, unsafe { nil })
	second_buffer = vk.Buffer(unsafe { nil })
	second_released := allocator.release(mut second_allocation)
	assert second_released
	assert allocator.trim_empty_blocks() == 2
	assert allocator.stats().block_count == 0
}

fn main() {
	run() or { panic(err) }
}
