module main

// Keep this helper for compatibility with older V3 compilers (vlang/v#31481).
// Passing the pointer value into a fresh scope prevents a heap-promoted
// pointer slot from being used as the byte-store destination.
fn store_mapped_byte(mapped voidptr, value u8) {
	unsafe {
		*(&u8(mapped)) = value
	}
}
