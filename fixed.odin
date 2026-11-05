package main

import "core:math"

// 16.16 fixed point: the top 16 bits are the integer part, the bottom 16
// the fraction.
Fixed :: distinct i32

FIXED_SHIFT :: 16
FIXED_ONE :: Fixed(1 << FIXED_SHIFT)
FIXED_HALF :: FIXED_ONE / 2

fx_from_int :: proc(n: int) -> Fixed {
	return Fixed(n << FIXED_SHIFT)
}

// Arithmetic shift, so this floors (-1.5 becomes -2, not -1).
fx_to_int :: proc(a: Fixed) -> int {
	return int(a) >> FIXED_SHIFT
}

// The raw product of two 16.16 numbers is 32.32, so go through i64 and
// shift back down. What the 386 did with imul and shrd.
fx_mul :: proc(a, b: Fixed) -> Fixed {
	return Fixed((i64(a) * i64(b)) >> FIXED_SHIFT)
}

fx_div :: proc(a, b: Fixed) -> Fixed {
	return Fixed((i64(a) << FIXED_SHIFT) / i64(b))
}

// Binary angles: a full circle is 1024 units, so wrapping is a bitmask
// instead of a modulo or a float compare.
ANGLES :: 1024
ANGLE_MASK :: ANGLES - 1

Angle :: distinct u16

sin_table: [ANGLES]Fixed

// Reciprocals of small integers. Lets the renderer do "1/distance" with a
// lookup instead of a divide.
RECIP_SIZE :: 4096
recip_table: [RECIP_SIZE]Fixed

// Floats are used here, once, at startup, to fill the tables.
init_tables :: proc() {
	for i in 0 ..< ANGLES {
		rad := f64(i) / f64(ANGLES) * 2 * math.PI
		sin_table[i] = Fixed(math.round(math.sin(rad) * f64(1 << FIXED_SHIFT)))
	}

	recip_table[0] = Fixed(max(i32))
	for n in 1 ..< RECIP_SIZE {
		recip_table[n] = FIXED_ONE / Fixed(n)
	}

	// Cheap sanity checks. If these fire, the math is wrong.
	assert(fx_mul(fx_from_int(3), FIXED_HALF) == fx_from_int(3) / 2)
	assert(fx_sin(0) == 0)
	assert(fx_sin(ANGLES / 4) == FIXED_ONE)
	assert(fx_cos(0) == FIXED_ONE)
	assert(fx_to_int(fx_from_int(-5)) == -5)
}

fx_sin :: proc(a: Angle) -> Fixed {
	return sin_table[int(a) & ANGLE_MASK]
}

// Cosine is just sine shifted by a quarter turn.
fx_cos :: proc(a: Angle) -> Fixed {
	return sin_table[(int(a) + ANGLES / 4) & ANGLE_MASK]
}

fx_recip :: proc(n: int) -> Fixed {
	return recip_table[clamp(n, 0, RECIP_SIZE - 1)]
}
