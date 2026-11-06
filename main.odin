package main

import "core:fmt"
import "core:mem"
import rl "vendor:raylib"

//odinfmt: disable
SCREEN_W :: 320
SCREEN_H :: 200
SCALE    :: 4

// Each channel is 0..63, exactly like the VGA DAC.
Palette_Entry :: struct {
	r, g, b: u8,
}

Framebuffer :: [SCREEN_W * SCREEN_H]u8
Palette     :: [256]Palette_Entry
RGBA_Buffer :: [SCREEN_W * SCREEN_H]rl.Color
//odinfmt: enable

// 16 base colors x 16 shades. Index = base*16 + shade (0 = brightest, 15 = darkest).
// 6-bit channels. Only the first 7 bases are used so far.
palette_bases := [?][3]u8 {
	{50, 50, 50}, // 0 gray
	{50, 20, 14}, // 1 brick
	{24, 30, 52}, // 2 stone
	{20, 44, 20}, // 3 green (spare)
	{34, 24, 14}, // 4 floor
	{22, 22, 30}, // 5 ceiling
	{46, 44, 38}, // 6 mortar
	{63, 63, 63}, // 7 UI text
}

dac_to_8bit :: proc(v: u8) -> u8 {
	return (v << 2) | (v >> 4)
}

build_palette :: proc(pal: ^Palette) {
	for base, b in palette_bases {
		for s in 0 ..< 16 {
			k := 16 - s
			pal[b * 16 + s] = {
				u8(int(base[0]) * k / 16),
				u8(int(base[1]) * k / 16),
				u8(int(base[2]) * k / 16),
			}
		}
	}
}

put_pixel :: proc(fb: ^Framebuffer, x, y: int, c: u8) {
	if x < 0 || x >= SCREEN_W || y < 0 || y >= SCREEN_H {
		return
	}
	fb[y * SCREEN_W + x] = c
}

present :: proc(fb: ^Framebuffer, pal: ^Palette, out: ^RGBA_Buffer) {
	for i in 0 ..< SCREEN_W * SCREEN_H {
		e := pal[fb[i]]
		out[i] = {dac_to_8bit(e.r), dac_to_8bit(e.g), dac_to_8bit(e.b), 255}
	}
}

main :: proc() {
	when TRACK_MEMORY {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		tracker = &track
		defer {
			for _, leak in track.allocation_map {
				fmt.eprintf("LEAK: %v bytes, allocated at %v\n", leak.size, leak.location)
			}
			for bad in track.bad_free_array {
				fmt.eprintf("BAD FREE at %v\n", bad.location)
			}
			mem.tracking_allocator_destroy(&track)
			tracker = nil
		}
	}

	init_memory()
	context.temp_allocator = mem.arena_allocator(&frame_arena)
	perm := mem.arena_allocator(&perm_arena)

	rl.InitWindow(SCREEN_W * SCALE, SCREEN_H * SCALE, "Mode 13h")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	rl.DisableCursor()

	scrshot := 0

	fb := new(Framebuffer, perm) // zeroed, and off the stack
	rgba := new(RGBA_Buffer, perm)
	pal: Palette

	build_palette(&pal)
	build_colormap(&pal)
	init_tables()
	init_raycaster()

	player := Player {
		x     = fx_from_int(8) + FIXED_HALF,
		y     = fx_from_int(6) + FIXED_HALF,
		z     = EYE_HEIGHT,
		angle = 0,
	}

	img := rl.GenImageColor(SCREEN_W, SCREEN_H, rl.BLACK)
	tex := rl.LoadTextureFromImage(img)
	rl.UnloadImage(img)
	defer rl.UnloadTexture(tex)
	rl.SetTextureFilter(tex, .POINT)

	src := rl.Rectangle{0, 0, SCREEN_W, SCREEN_H}

	for !rl.WindowShouldClose() {
		defer free_all(context.temp_allocator) // frame arena back to empty

		if rl.IsKeyPressed(.F11) do rl.ToggleBorderlessWindowed()

		update_player(&player)
		render_view(fb, &player)
		draw_hud(fb, &player)

		present(fb, &pal, rgba)

		if rl.IsKeyPressed(.F12) {
			shot_img := rl.Image {
				data    = &rgba[0],
				width   = SCREEN_W,
				height  = SCREEN_H,
				mipmaps = 1,
				format  = .UNCOMPRESSED_R8G8B8A8,
			}
			_ = rl.ExportImage(shot_img, fmt.ctprintf("screenshot_%d.png", scrshot))
			scrshot += 1
		}

		rl.UpdateTexture(tex, &rgba[0])

			//odinfmt:disable
		// Largest whole-number scale that fits, centered.
		sw    := int(rl.GetScreenWidth())
		sh    := int(rl.GetScreenHeight())
		scale := max(1, min(sw / SCREEN_W, sh / SCREEN_H))
		dw    := SCREEN_W * scale
		dh    := SCREEN_H * scale
		dst   := rl.Rectangle{f32((sw - dw) / 2), f32((sh - dh) / 2), f32(dw), f32(dh)}
		//odinfmt:enable
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		rl.DrawTexturePro(tex, src, dst, {0, 0}, 0, rl.WHITE)
		rl.EndDrawing()
	}
}
