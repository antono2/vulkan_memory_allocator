module main

fn escaped_mapped_byte_store(bytes []u8, value u8) &voidptr {
	mut mapped := voidptr(bytes.data)
	store_mapped_byte(mapped, value)
	return &mapped
}

fn test_mapped_byte_store_preserves_an_escaped_pointer() {
	for value in [u8(0), 21, 255] {
		mut bytes := [u8(7), 8, 9, 10]
		pointer_slot := escaped_mapped_byte_store(bytes, value)
		assert bytes == [value, u8(8), 9, 10]
		assert unsafe { *pointer_slot } == bytes.data
	}
}
