// Checks unavailable and non-transfer families before device creation.
module main

import antono2.vulkan as vk

fn test_transfer_family_selection_rejects_unavailable_and_sparse_only_queues() {
	if _ := select_transfer_family([]vk.QueueFamilyProperties{}) { assert false
	 }
	if _ := select_transfer_family([
		vk.QueueFamilyProperties{ queueCount: 0, queueFlags: u32(vk.QueueFlagBits.transfer) },
		vk.QueueFamilyProperties{ queueCount: 1, queueFlags: u32(vk.QueueFlagBits.sparse_binding) },
	])
	{
		assert false
	}
	families := [
		vk.QueueFamilyProperties{
			queueCount: 1
			queueFlags: u32(vk.QueueFlagBits.sparse_binding)
		},
		vk.QueueFamilyProperties{
			queueCount: 0
			queueFlags: u32(vk.QueueFlagBits.graphics)
		},
		vk.QueueFamilyProperties{
			queueCount: 1
			queueFlags: u32(vk.QueueFlagBits.compute)
		},
		vk.QueueFamilyProperties{
			queueCount: 1
			queueFlags: u32(vk.QueueFlagBits.transfer)
		},
	]
	assert (select_transfer_family(families) or { panic('missing compute transfer support') }) == 2
	assert (select_transfer_family([
		vk.QueueFamilyProperties{ queueCount: 1, queueFlags: u32(vk.QueueFlagBits.graphics) },
	]) or { panic('missing graphics transfer support') }) == 0
}
