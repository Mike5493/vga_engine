package main

import "core:fmt"
import rl "vendor:raylib"

// Palette base 7 is the UI ramp (white). Shadow is its darkest shade.
//odinfmt:disable
UI_TEXT   :: u8(7 << 4)
UI_SHADOW :: u8((7 << 4) | 15)

FONT_W :: 5
FONT_H :: 7

FONT_CHARS :: " -.:/0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

// 5 columns per glyph, bit 0 = top row. Tweak a byte to change a pixel column.
font_glyphs := [?][FONT_W]u8{
	{0x00, 0x00, 0x00, 0x00, 0x00}, // ' '
	{0x08, 0x08, 0x08, 0x08, 0x08}, // -
	{0x00, 0x00, 0x60, 0x60, 0x00}, // .
	{0x00, 0x00, 0x14, 0x00, 0x00}, // :
	{0x20, 0x10, 0x08, 0x04, 0x02}, // /
	{0x3E, 0x51, 0x49, 0x45, 0x3E}, // 0
	{0x00, 0x42, 0x7F, 0x40, 0x00}, // 1
	{0x72, 0x49, 0x49, 0x49, 0x46}, // 2
	{0x21, 0x41, 0x49, 0x4D, 0x33}, // 3
	{0x18, 0x14, 0x12, 0x7F, 0x10}, // 4
	{0x27, 0x45, 0x45, 0x45, 0x39}, // 5
	{0x3C, 0x4A, 0x49, 0x49, 0x31}, // 6
	{0x41, 0x21, 0x11, 0x09, 0x07}, // 7
	{0x36, 0x49, 0x49, 0x49, 0x36}, // 8
	{0x46, 0x49, 0x49, 0x29, 0x1E}, // 9
	{0x7E, 0x11, 0x11, 0x11, 0x7E}, // A
	{0x7F, 0x49, 0x49, 0x49, 0x36}, // B
	{0x3E, 0x41, 0x41, 0x41, 0x22}, // C
	{0x7F, 0x41, 0x41, 0x41, 0x3E}, // D
	{0x7F, 0x49, 0x49, 0x49, 0x41}, // E
	{0x7F, 0x09, 0x09, 0x09, 0x01}, // F
	{0x3E, 0x41, 0x41, 0x51, 0x73}, // G
	{0x7F, 0x08, 0x08, 0x08, 0x7F}, // H
	{0x00, 0x41, 0x7F, 0x41, 0x00}, // I
	{0x20, 0x40, 0x41, 0x3F, 0x01}, // J
	{0x7F, 0x08, 0x14, 0x22, 0x41}, // K
	{0x7F, 0x40, 0x40, 0x40, 0x40}, // L
	{0x7F, 0x02, 0x1C, 0x02, 0x7F}, // M
	{0x7F, 0x04, 0x08, 0x10, 0x7F}, // N
	{0x3E, 0x41, 0x41, 0x41, 0x3E}, // O
	{0x7F, 0x09, 0x09, 0x09, 0x06}, // P
	{0x3E, 0x41, 0x51, 0x21, 0x5E}, // Q
	{0x7F, 0x09, 0x19, 0x29, 0x46}, // R
	{0x26, 0x49, 0x49, 0x49, 0x32}, // S
	{0x03, 0x01, 0x7F, 0x01, 0x03}, // T
	{0x3F, 0x40, 0x40, 0x40, 0x3F}, // U
	{0x1F, 0x20, 0x40, 0x20, 0x1F}, // V
	{0x3F, 0x40, 0x38, 0x40, 0x3F}, // W
	{0x63, 0x14, 0x08, 0x14, 0x63}, // X
	{0x03, 0x04, 0x78, 0x04, 0x03}, // Y
	{0x61, 0x59, 0x49, 0x4D, 0x43}, // Z
}

#assert(len(font_glyphs) == len(FONT_CHARS))

debug_on:    bool
light_popup: int // frames left to show the light level readout
crosshair_on := true
//odinfmt:enable

glpyh_index :: proc(ch: u8) -> int {
	c := ch
	if c >= 'a' && c <= 'z' do c -= 32 // lowercase -> uppercase

	chars := FONT_CHARS
	for i in 0 ..< len(chars) {
		if chars[i] == c do return i
	}
	return 0 // unknown character -> space
}

draw_glpyh :: proc(fb: ^Framebuffer, x, y, g: int, color: u8) {
	for col in 0 ..< FONT_W {
		bits := font_glyphs[g][col]
		for row in 0 ..< FONT_H {
			if (bits >> u32(row)) & 1 != 0 {
				put_pixel(fb, x + col, y + row, color)
			}
		}
	}
}

draw_text :: proc(fb: ^Framebuffer, x, y: int, text: string, color: u8) {
	cx := x
	for i in 0 ..< len(text) {
		g := glpyh_index(text[i])
		draw_glpyh(fb, cx + 1, y + 1, g, UI_SHADOW) // drop shadow keeps it readble
		draw_glpyh(fb, cx, y, g, color)
		cx += FONT_W + 1
	}
}

fill_rect :: proc(fb: ^Framebuffer, x, y, w, h: int, color: u8) {
	for j in 0 ..< h {
		for i in 0 ..< w {
			put_pixel(fb, x + i, y + j, color)
		}
	}
}

// Fractional part of a 16.16 value is 0..99.
frac100 :: proc(a: Fixed) -> int {
	return ((int(a) & 0xFFFF) * 100) >> FIXED_SHIFT
}

draw_crosshair :: proc(fb: ^Framebuffer) {
	cx := VIEW_W / 2
	cy := VIEW_H / 2
	for pass in 0 ..< 2 {
		c := UI_SHADOW if pass == 0 else UI_TEXT
		o := 1 if pass == 0 else 0
		for i in 3 ..= 5 {
			put_pixel(fb, cx - i + o, cy + o, c)
			put_pixel(fb, cx + i + o, cy + o, c)
			put_pixel(fb, cx + o, cy - i + o, c)
			put_pixel(fb, cx + o, cy + i + o, c)
		}
	}
}

draw_hud :: proc(fb: ^Framebuffer, player: ^Player) {
	buf: [64]u8

	if crosshair_on do draw_crosshair(fb)

	// Light level readout: shows briefly after torch is changed.
	if light_popup > 0 {
		light_popup -= 1
		text := fmt.bprint(buf[:], "LIGHT %d/%d", torch_power, NUM_LEVELS - 1)
		draw_text(fb, 4, 4, text, UI_TEXT)
		fill_rect(fb, 3, 14, NUM_LEVELS * 2 + 2, 5, UI_SHADOW)
		fill_rect(fb, 4, 15, torch_power * 2, 3, UI_TEXT)
	}

	// F3 debug readout.
	if debug_on {
		y := SCREEN_H - 50
		angle := int(player.angle) & ANGLE_MASK

		text := fmt.bprint(
			buf[:],
			"X %d.%02d  Y %d.%02d",
			fx_to_int(player.x),
			frac100(player.x),
			fx_to_int(player.y),
			frac100(player.y),
		)
		draw_text(fb, 4, y, text, UI_TEXT)

		text = fmt.bprintf(
			buf[:],
			"TILE %d,%d  ANGLE %d (%d DEG)",
			fx_to_int(player.x),
			fx_to_int(player.y),
			angle,
			angle * 360 / ANGLES,
		)
		draw_text(fb, 4, y + 9, text, UI_TEXT)

		text = fmt.bprintf(buf[:], "TORCH %d  FPS %d", torch_power, rl.GetFPS())
		draw_text(fb, 4, y + 18, text, UI_TEXT)

		if noclip {
			draw_text(fb, 4, y + 27, "NOCLIP", UI_TEXT)
		}

		if tracker != nil {
			text = fmt.bprintf(
				buf[:],
				"HEAP %d KB  ALLOCS %d",
				tracker.current_memory_allocated / 1024,
				tracker.total_allocation_count,
			)
			draw_text(fb, 4, y + 36, text, UI_TEXT)
		}

		text = fmt.bprintf(
			buf[:],
			"PERM %d/%d KB  FRAME PEAK %d KB",
			perm_arena.offset / 1024,
			PERM_SIZE / 1024,
			frame_arena.peak_used / 1024,
		)
		draw_text(fb, 4, y + 45, text, UI_TEXT)
	}
}
