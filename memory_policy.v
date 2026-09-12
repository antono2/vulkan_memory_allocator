module vkmemalloc

import antono2.vulkan as vk

// MemoryUsage describes how an allocation is expected to move between the CPU
// and GPU. It is a policy hint; required_flags always remain mandatory.
pub enum MemoryUsage {
	automatic
	gpu_only
	upload
	readback
}

// BudgetPolicy controls how reported or physical heap capacity affects memory
// type selection.
pub enum BudgetPolicy {
	prefer_within
	ignore
	require_within
}

// AllocationOptions describes required and preferred memory properties. The
// usage profile supplies sensible defaults, while the explicit flag sets let
// callers refine them for specialized resources.
pub struct AllocationOptions {
pub:
	usage           MemoryUsage
	required_flags  vk.MemoryPropertyFlags
	preferred_flags vk.MemoryPropertyFlags
	avoided_flags   vk.MemoryPropertyFlags
	budget_policy   BudgetPolicy = .prefer_within
}

// MemoryTypeChoice explains why a Vulkan memory type was selected.
pub struct MemoryTypeChoice {
pub:
	index            u32
	heap_index       u32
	property_flags   vk.MemoryPropertyFlags
	heap_size        u64
	heap_budget      u64
	heap_usage       u64
	remaining_budget u64
	within_budget    bool
	budget_reported  bool
	preference_score int
}

// MemoryHeapStats combines Vulkan heap capacity/budget information with the
// blocks currently committed by this allocator.
pub struct MemoryHeapStats {
pub:
	heap_index          u32
	size                u64
	budget              u64
	usage               u64
	remaining_budget    u64
	allocator_committed u64
	allocator_used      u64
	device_local        bool
	budget_reported     bool
}

struct HeapBudgetSnapshot {
	reported bool
	budgets  []u64
	usages   []u64
}

// supports_memory_budget reports whether a physical device exposes
// VK_EXT_memory_budget through this allocator's Vulkan 1.1 query path. Call it
// after the Vulkan loader and instance commands are initialized, and enable
// that device extension before opting the allocator into live budget queries.
pub fn supports_memory_budget(physical_device vk.PhysicalDevice) bool {
	mut device_properties := vk.PhysicalDeviceProperties{}
	vk.get_physical_device_properties(physical_device, mut &device_properties)
	if device_properties.apiVersion < vk.api_version_1_1 {
		return false
	}
	for {
		mut count := u32(0)
		mut no_properties := unsafe { nil }
		if vk.enumerate_device_extension_properties(physical_device, unsafe { nil }, &count, mut no_properties) != .success
			|| count == 0 {
			return false
		}
		mut properties := []vk.ExtensionProperties{len: int(count)}
		result := vk.enumerate_device_extension_properties(physical_device, unsafe { nil }, &count, mut
			properties[0])
		if result == .incomplete {
			continue
		}
		if result != .success {
			return false
		}
		for index in 0 .. int(count) {
			name := unsafe { cstring_to_vstring(&properties[index].extensionName[0]) }
			if name == 'VK_EXT_memory_budget' {
				return true
			}
		}
		return false
	}
	return false
}

fn memory_flag(flag vk.MemoryPropertyFlagBits) vk.MemoryPropertyFlags {
	return vk.MemoryPropertyFlags(u32(flag))
}

fn has_memory_flags(flags vk.MemoryPropertyFlags, required vk.MemoryPropertyFlags) bool {
	return (flags & required) == required
}

fn memory_flag_count(flags vk.MemoryPropertyFlags) int {
	mut value := u32(flags)
	mut count := 0
	for value != 0 {
		count += int(value & 1)
		value >>= 1
	}
	return count
}

fn usage_required_flags(usage MemoryUsage) vk.MemoryPropertyFlags {
	return match usage {
		.gpu_only { memory_flag(.device_local) }
		.upload, .readback { memory_flag(.host_visible) }
		.automatic { vk.MemoryPropertyFlags(0) }
	}
}

fn usage_preference_score(usage MemoryUsage, flags vk.MemoryPropertyFlags) int {
	device_local := has_memory_flags(flags, memory_flag(.device_local))
	host_coherent := has_memory_flags(flags, memory_flag(.host_coherent))
	host_cached := has_memory_flags(flags, memory_flag(.host_cached))
	device_uncached := has_memory_flags(flags, memory_flag(.device_uncached_bit_amd))
	return match usage {
		.automatic {
			memory_score(device_local, 16)
		}
		.gpu_only {
			memory_score(device_uncached, -4)
		}
		.upload {
			memory_score(host_coherent, 16) + memory_score(device_local, 8) +
				memory_score(host_cached, 2) + memory_score(device_uncached, -4)
		}
		.readback {
			memory_score(host_cached, 16) + memory_score(host_coherent, 8) +
				memory_score(device_local, 2) + memory_score(device_uncached, -4)
		}
	}
}

fn memory_score(condition bool, points int) int {
	if condition {
		return points
	}
	return 0
}

fn memory_preference_score(options AllocationOptions, flags vk.MemoryPropertyFlags) int {
	preferred := memory_flag_count(flags & options.preferred_flags)
	avoided := memory_flag_count(flags & options.avoided_flags)
	return usage_preference_score(options.usage, flags) + preferred * 4 - avoided * 32
}

fn heap_budget_values(props vk.PhysicalDeviceMemoryProperties, heap_index u32, snapshot HeapBudgetSnapshot) (u64, u64, bool) {
	heap_size := u64(props.memoryHeaps[heap_index].size)
	if int(heap_index) < snapshot.budgets.len && int(heap_index) < snapshot.usages.len {
		budget := if snapshot.budgets[heap_index] > 0 {
			snapshot.budgets[heap_index]
		} else {
			heap_size
		}
		return budget, snapshot.usages[heap_index], snapshot.reported
	}
	return heap_size, 0, false
}

fn memory_choice_is_better(candidate MemoryTypeChoice, current MemoryTypeChoice, policy BudgetPolicy) bool {
	if policy == .prefer_within && candidate.within_budget != current.within_budget {
		return candidate.within_budget
	}
	if candidate.preference_score != current.preference_score {
		return candidate.preference_score > current.preference_score
	}
	if policy != .ignore && candidate.remaining_budget != current.remaining_budget {
		return candidate.remaining_budget > current.remaining_budget
	}
	return candidate.index < current.index
}

fn ranked_memory_types(props vk.PhysicalDeviceMemoryProperties, type_bits u32, request_size u64, options AllocationOptions, snapshot HeapBudgetSnapshot) []MemoryTypeChoice {
	required := usage_required_flags(options.usage) | options.required_flags
	mut choices := []MemoryTypeChoice{}
	for index in 0 .. int(props.memoryTypeCount) {
		if index >= int(vk.max_memory_types) || (type_bits & (u32(1) << u32(index))) == 0 {
			continue
		}
		memory_type := props.memoryTypes[index]
		if !has_memory_flags(memory_type.propertyFlags, required)
			|| memory_type.heapIndex >= props.memoryHeapCount {
			continue
		}
		heap_size := u64(props.memoryHeaps[memory_type.heapIndex].size)
		budget, usage, reported := heap_budget_values(props, memory_type.heapIndex, snapshot)
		remaining := if usage < budget { budget - usage } else { u64(0) }
		within_budget := request_size <= remaining
		if options.budget_policy == .require_within && !within_budget {
			continue
		}
		choice := MemoryTypeChoice{
			index:            u32(index)
			heap_index:       memory_type.heapIndex
			property_flags:   memory_type.propertyFlags
			heap_size:        heap_size
			heap_budget:      budget
			heap_usage:       usage
			remaining_budget: remaining
			within_budget:    within_budget
			budget_reported:  reported
			preference_score: memory_preference_score(options, memory_type.propertyFlags)
		}
		mut inserted := false
		for position, existing in choices {
			if memory_choice_is_better(choice, existing, options.budget_policy) {
				choices.insert(position, choice)
				inserted = true
				break
			}
		}
		if !inserted {
			choices << choice
		}
	}
	return choices
}

// select_memory_type applies the portable usage/property policy using physical
// heap sizes. Allocator.select_memory_type additionally uses live heap budgets
// when VK_EXT_memory_budget integration was enabled at allocator creation.
pub fn select_memory_type(props vk.PhysicalDeviceMemoryProperties, type_bits u32, request_size u64, options AllocationOptions) ?MemoryTypeChoice {
	choices := ranked_memory_types(props, type_bits, request_size, options, HeapBudgetSnapshot{})
	if choices.len == 0 {
		return none
	}
	return choices[0]
}

fn (a &Allocator) heap_budget_snapshot() HeapBudgetSnapshot {
	mut budgets := []u64{len: int(a.props.memoryHeapCount)}
	mut usages := []u64{len: int(a.props.memoryHeapCount)}
	for heap_index in 0 .. int(a.props.memoryHeapCount) {
		if a.memory_budget_reported && heap_index < a.heap_budgets.len
			&& heap_index < a.heap_usages.len {
			budgets[heap_index] = a.heap_budgets[heap_index]
			usages[heap_index] = a.heap_usages[heap_index]
			continue
		}
		budgets[heap_index] = u64(a.props.memoryHeaps[heap_index].size)
		if !isnil(a.planner) {
			committed, _ := a.planner.heap_stats(&a.props, u32(heap_index))
			usages[heap_index] = committed
		}
	}
	return HeapBudgetSnapshot{
		reported: a.memory_budget_reported
		budgets:  budgets
		usages:   usages
	}
}

// refresh_memory_budget refreshes VK_EXT_memory_budget estimates when the
// allocator was created with memory_budget_enabled. It returns false when the
// optional integration is unavailable; physical heap sizes remain usable.
pub fn (mut a Allocator) refresh_memory_budget() bool {
	if !a.create_info.memory_budget_enabled || a.api_version < vk.api_version_1_1 {
		return false
	}
	mut budget := vk.PhysicalDeviceMemoryBudgetPropertiesEXT{}
	mut properties := vk.PhysicalDeviceMemoryProperties2{
		pNext: voidptr(&budget)
	}
	vk.get_physical_device_memory_properties2(a.create_info.physical_device, mut &properties)
	a.props = properties.memoryProperties
	heap_count := int(a.props.memoryHeapCount)
	a.heap_budgets = []u64{len: heap_count}
	a.heap_usages = []u64{len: heap_count}
	mut reported := false
	for heap_index in 0 .. heap_count {
		a.heap_budgets[heap_index] = u64(budget.heapBudget[heap_index])
		a.heap_usages[heap_index] = u64(budget.heapUsage[heap_index])
		if a.heap_budgets[heap_index] > 0 {
			reported = true
		}
	}
	a.memory_budget_reported = reported
	return reported
}

// select_memory_type ranks every compatible type and returns an explainable
// choice. It uses the latest refreshed budget snapshot when that optional
// integration is enabled; otherwise allocator-owned commitment is used.
pub fn (mut a Allocator) select_memory_type(type_bits u32, request_size u64, options AllocationOptions) ?MemoryTypeChoice {
	choices := a.rank_memory_types(type_bits, request_size, options)
	if choices.len == 0 {
		return none
	}
	return choices[0]
}

fn (mut a Allocator) rank_memory_types(type_bits u32, request_size u64, options AllocationOptions) []MemoryTypeChoice {
	return ranked_memory_types(a.props, type_bits, request_size, options, a.heap_budget_snapshot())
}

// A buffer can reuse a compatible block without increasing heap usage. Keep
// over-budget candidates available for that reuse even when new block creation
// is forbidden by require_within.
fn (mut a Allocator) rank_buffer_memory_types(type_bits u32, request_size u64, options AllocationOptions) []MemoryTypeChoice {
	if options.budget_policy != .require_within {
		return a.rank_memory_types(type_bits, request_size, options)
	}
	return a.rank_memory_types(type_bits, request_size, AllocationOptions{
		usage:           options.usage
		required_flags:  options.required_flags
		preferred_flags: options.preferred_flags
		avoided_flags:   options.avoided_flags
		budget_policy:   .prefer_within
	})
}

// memory_heaps returns one diagnostics record per Vulkan memory heap. Reported
// budget/usage values come from VK_EXT_memory_budget when enabled; the portable
// fallback uses heap size and this allocator's own committed blocks.
pub fn (a &Allocator) memory_heaps() []MemoryHeapStats {
	snapshot := a.heap_budget_snapshot()
	mut heaps := []MemoryHeapStats{cap: int(a.props.memoryHeapCount)}
	for heap_index in 0 .. int(a.props.memoryHeapCount) {
		mut committed := u64(0)
		mut used := u64(0)
		if !isnil(a.planner) {
			committed, used = a.planner.heap_stats(&a.props, u32(heap_index))
		}
		budget, usage, reported := heap_budget_values(a.props, u32(heap_index), snapshot)
		heaps << MemoryHeapStats{
			heap_index:          u32(heap_index)
			size:                u64(a.props.memoryHeaps[heap_index].size)
			budget:              budget
			usage:               usage
			remaining_budget:    if usage < budget { budget - usage } else { u64(0) }
			allocator_committed: committed
			allocator_used:      used
			device_local:        (a.props.memoryHeaps[heap_index].flags & u32(vk.MemoryHeapFlagBits.device_local)) != 0
			budget_reported:     reported
		}
	}
	return heaps
}
