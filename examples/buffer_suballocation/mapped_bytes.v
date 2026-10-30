module main

// Pass the pointer value into a fresh local scope: vlang/v#31481 otherwise
// casts a heap-promoted voidptr slot's address instead of its stored value.
fn store_mapped_byte(mapped voidptr, value u8) {
	unsafe { *(&u8(mapped)) = value }
}
