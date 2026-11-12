module main

// Keep this helper for older V3 compilers affected by vlang/v#31481.
// Newer V3 fixes that issue, but stable V 0.5.2 still fails its escaping-pointer
// reproducer, even though this example passes without the helper. Passing the
// pointer value into a fresh scope keeps byte stores directed at mapped memory
// instead of a heap-promoted pointer slot.
fn store_mapped_byte(mapped voidptr, value u8) {
	unsafe {
		*(&u8(mapped)) = value
	}
}
