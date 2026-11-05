package main

import rl "vendor:raylib"

VIEW_W :: SCREEN_W
VIEW_H :: SCREEN_H

MAP_W :: 16
MAP_H :: 16

//odinfmt:disable
TEX_SIZE     :: 64
NUM_TEXTURES :: 5
TEX_FLOOR    :: 3
TEX_CEIL     :: 4

// Palette bases (high nibble of a color index).
BRICK_BASE  :: 1
STONE_BASE  :: 2
FLOOR_BASE  :: 4
CEIL_BASE   :: 5
MORTAR_BASE :: 6

// Player and view
PLANE_SCALE   :: Fixed(43253)	// 0.66, ~66 degree horizontal FOV
PROJ_DIST     :: 240			// projection scale: wall height in pixels at dist 1
MIN_RAY       :: Fixed(256)		// clamp so 1/ray can't overflow 16.16
MIN_DIST	  :: Fixed(4096)	// 1/16 tile, keeps wall heights sane when wall hugging
MOVE_SPEED	  :: Fixed(4096)	// 1/16 tile per frame
PLAYER_RADIUS :: Fixed(13107)	// 0.2 tile
TURN_SPEED	  :: Angle(4)
MOUSE_SENS    :: 100.0          // 1/256 angle units per pixel of mouse movement

// Lighting
NUM_LEVELS :: 32 // colormap rows: 0 = full bright, 31 = nearly black
AMBIENT    :: 3  // brightness everywhere, even far from any light
TORCH_FALL :: 2  // torch brightness lost per tile of distance
LIGHT_FALL :: 2  // point light brightness lost per tile squared
//odinfmt:enable

Texture :: [TEX_SIZE * TEX_SIZE]u8

Player :: struct {
	x, y:      Fixed,
	angle:     Angle,
	turn_frac: int, // leftover mouse turning, in 1/256 angle units
}

Light :: struct {
	x, y:  Fixed,
	power: int, // brightness at the source
}

lights := [?]Light {
	{x = 0x38000, y = 0x58000, power = 24}, // (3.5, 5.5)
	{x = 0xC8000, y = 0xA8000, power = 24}, // (12.5, 10.5)
	{x = 0x78000, y = 0xD8000, power = 24}, // (7.5, 13.5)
}

//odinfmt: disable
map_src := [MAP_H]string{
	"2222222222222222",
	"2..............2",
	"2..1111....222.2",
	"2..1.......2...2",
	"2..1.......2...2",
	"2..............2",
	"2....11.....1..2",
	"2..............2",
	"2...2222.......2",
	"2...2..........2",
	"2...2...1111...2",
	"2.......1......2",
	"2..11...1..22..2",
	"2..1.......2...2",
	"2..............2",
	"2222222222222222",
}

// Globals
world_map:  [MAP_H][MAP_W]u8
textures:   [NUM_TEXTURES]Texture
column_x:   [VIEW_W]Fixed // camera-plane position of each column, -1..+1
row_dist:   [VIEW_H]Fixed // distance to the floor under each screen row (lower half used)
colormap:   [NUM_LEVELS][256]u8
noclip:     bool
mouse_look: bool = true
torch_power := 26 		// brightness at the player, 0..31 ([ and ] change it)
//odinfmt:enable

map_at :: proc(x, y: int) -> u8 {
	if x < 0 || x >= MAP_W || y < 0 || y >= MAP_H {
		return 1 // outside the map counts as a wall
	}
	return world_map[y][x]
}

// Tiny integer hash for procedural texture noise.
hash2 :: proc(x, y: int) -> u32 {
	h := u32(x) * 374_761_393 + u32(y) * 668_265_263
	h = (h ~ (h >> 13)) * 127_412_6177
	return h ~ (h >> 16)
}

make_brick :: proc(tex: ^Texture) {
	for y in 0 ..< TEX_SIZE {
		row := y / 8
		off := (row & 1) * 8 // odd rows are offset by half a brick
		for x in 0 ..< TEX_SIZE {
			bx := ((x + off) / 16) % 4
			i := y * TEX_SIZE + x
			if y % 8 == 0 || (x + off) % 16 == 0 {
				tex[i] = u8(MORTAR_BASE << 4) | u8(hash2(x, y) % 3)
			} else {
				b := hash2(bx, row) % 4 + hash2(x, y) % 2
				tex[i] = u8(BRICK_BASE << 4) | u8(b)
			}
		}
	}
}

make_stone :: proc(tex: ^Texture) {
	for y in 0 ..< TEX_SIZE {
		for x in 0 ..< TEX_SIZE {
			i := y * TEX_SIZE + x
			if x % 32 == 0 || y % 32 == 0 {
				tex[i] = u8(9 + hash2(x, y) % 3) // dark gray crack line (base 0)
			} else {
				b := hash2(x / 32, y / 32) % 4 + hash2(x, y) % 3
				tex[i] = u8(STONE_BASE << 4) | u8(b)
			}
		}
	}
}

make_floor :: proc(tex: ^Texture) {
	for y in 0 ..< TEX_SIZE {
		for x in 0 ..< TEX_SIZE {
			i := y * TEX_SIZE + x
			if x % 16 == 0 || y % 16 == 0 {
				tex[i] = u8(FLOOR_BASE << 4) | u8(7 + hash2(x, y) % 2) // dark seam
			} else {
				b := hash2(x / 16, y / 16) % 4 + hash2(x, y) % 2
				tex[i] = u8(FLOOR_BASE << 4) | u8(b)
			}
		}
	}
}

make_ceiling :: proc(tex: ^Texture) {
	for y in 0 ..< TEX_SIZE {
		for x in 0 ..< TEX_SIZE {
			i := y * TEX_SIZE + x
			if x % 32 < 2 || y % 32 < 2 {
				tex[i] = u8(CEIL_BASE << 4) | u8(6 + hash2(x, y) % 2) // dark beam
			} else {
				b := hash2(x / 32, y / 32) % 3 + hash2(x, y) % 2
				tex[i] = u8(CEIL_BASE << 4) | u8(b)
			}
		}
	}
}

init_raycaster :: proc() {
	for row, y in map_src {
		for x in 0 ..< MAP_W {
			c := row[x]
			world_map[y][x] = 0 if c == '.' else c - '0'
		}
	}

	make_brick(&textures[1])
	make_stone(&textures[2])
	make_floor(&textures[TEX_FLOOR])
	make_ceiling(&textures[TEX_CEIL])

	// Distance to the floor seen through each row's center (eye is at mid-height).
	for y in VIEW_H / 2 ..< VIEW_H {
		row_dist[y] = Fixed((PROJ_DIST << FIXED_SHIFT) / (2 * y - VIEW_H + 1))
	}

	// Pixel-center camera positions, so the view is symetric.
	for x in 0 ..< VIEW_W {
		column_x[x] = Fixed(((2 * x + 1 - VIEW_W) << FIXED_SHIFT) / VIEW_W)
	}
}

draw_floor_ceiling :: proc(
	fb: ^Framebuffer,
	player: ^Player,
	dir_x, dir_y, plane_x, plane_y: Fixed,
) {
	floor_tex := &textures[TEX_FLOOR]
	ceil_tex := &textures[TEX_CEIL]

	for y in VIEW_H / 2 ..< VIEW_H {
		dist := row_dist[y]
		base_b := AMBIENT + torch_light(dist)

		// World position under the leftmost pixel of this row...
		wx := player.x + fx_mul(dist, dir_x + fx_mul(plane_x, column_x[0]))
		wy := player.y + fx_mul(dist, dir_y + fx_mul(plane_y, column_x[0]))
		// ...and how far it moves for each pixel to the right.
		dx := Fixed(int(fx_mul(dist, plane_x)) * 2 / VIEW_W)
		dy := Fixed(int(fx_mul(dist, plane_y)) * 2 / VIEW_W)

		row_f := y * SCREEN_W
		row_c := (VIEW_H - 1 - y) * SCREEN_W // the mirrored row above the horizon

		for x in 0 ..< VIEW_W {
			tx := (int(wx) >> 10) & (TEX_SIZE - 1) // top 6 bits of the 16-bit fraction
			ty := (int(wy) >> 10) & (TEX_SIZE - 1)
			i := ty * TEX_SIZE + tx

			// Torch is per-row, point lights are per-pixel.
			lm := &colormap[level_for(base_b + light_at(wx, wy))]
			fb[row_f + x] = lm[floor_tex[i]]
			fb[row_c + x] = lm[ceil_tex[i]]

			wx += dx
			wy += dy
		}
	}
}

// Doom-style colormap build: for each light level, darken every palette color
// and find the closest color the palette actually contains.
build_colormap :: proc(pal: ^Palette) {
	used := len(palette_bases) * 16 // skip unused (black) palette slots

	for level in 0 ..< NUM_LEVELS {
		k := NUM_LEVELS - level // 32 (full) down to 1 (nearly black)
		for c in 0 ..< 256 {
			entry := pal[c]
			tr := int(entry.r) * k / NUM_LEVELS
			tg := int(entry.g) * k / NUM_LEVELS
			tb := int(entry.b) * k / NUM_LEVELS

			best := 0
			best_d := max(int)
			for i in 0 ..< used {
				p := pal[i]
				dr := tr - int(p.r)
				dg := tg - int(p.g)
				db := tb - int(p.b)
				d := dr * dr + dg * dg + db * db
				if d < best_d {
					best_d = d
					best = i
				}
			}
			colormap[level][c] = u8(best)
		}
	}
}

// Brightness (0..31) -> colormap row (0 = brightest)
level_for :: proc(b: int) -> int {
	return NUM_LEVELS - 1 - clamp(b, 0, NUM_LEVELS - 1)
}

// The player's torch: brightest at the player, fading with distance.
torch_light :: proc(dist: Fixed) -> int {
	return max(0, torch_power - ((int(dist) * TORCH_FALL) >> FIXED_SHIFT))
}

// Brightness contributed by all point lights at a world position.
light_at :: proc(wx, wy: Fixed) -> int {
	total := 0
	for l in lights {
		dx := wx - l.x
		dy := wy - l.y
		d2 := fx_mul(dx, dy) + fx_mul(dy, dy) // distance squared, in tiles^2
		total += max(0, l.power - ((int(d2) * LIGHT_FALL) >> FIXED_SHIFT))
	}
	return total
}

// Distance the ray travels per whole tile along one axis: 1 / |ray|.
ray_delta :: proc(ray: Fixed) -> Fixed {
	a := ray if ray >= 0 else -ray
	a = max(a, MIN_RAY)
	return fx_div(FIXED_ONE, a)
}

try_move :: proc(player: ^Player, dx, dy: Fixed) {
	// Test each axis separately so we can wall slide!
	new_x := player.x + dx
	probe_x := new_x + (PLAYER_RADIUS if dx > 0 else -PLAYER_RADIUS)
	if map_at(fx_to_int(probe_x), fx_to_int(player.y)) == 0 {
		player.x = new_x
	}

	new_y := player.y + dy
	probe_y := new_y + (PLAYER_RADIUS if dy > 0 else -PLAYER_RADIUS)
	if map_at(fx_to_int(player.x), fx_to_int(probe_y)) == 0 {
		player.y = new_y
	}
}

update_player :: proc(player: ^Player) {
	// Toggles
	if rl.IsKeyPressed(.F3) do debug_on = !debug_on
	if rl.IsKeyPressed(.N) do noclip = !noclip
	toggled_mouse := rl.IsKeyPressed(.M)
	if toggled_mouse {
		mouse_look = !mouse_look
		if mouse_look {
			rl.DisableCursor()
		} else {
			rl.EnableCursor()
		}
	}

	// Torch level
	if rl.IsKeyPressed(.RIGHT_BRACKET) {
		torch_power = min(torch_power + 2, NUM_LEVELS - 1)
		light_popup = 90
	}
	if rl.IsKeyPressed(.LEFT_BRACKET) {
		torch_power = max(torch_power - 2, 0)
		light_popup = 90
	}

	if rl.IsKeyDown(.LEFT) do player.angle -= TURN_SPEED
	if rl.IsKeyDown(.RIGHT) do player.angle += TURN_SPEED

	if mouse_look && !toggled_mouse {
		player.turn_frac += int(rl.GetMouseDelta().x * MOUSE_SENS)
		whole := player.turn_frac >> 8
		player.turn_frac -= whole << 8
		player.angle += Angle(whole)
	}

	// Movement
	speed := MOVE_SPEED
	if rl.IsKeyDown(.LEFT_SHIFT) do speed *= 2

	dx := fx_cos(player.angle)
	dy := fx_sin(player.angle)
	mx, my: Fixed

	if rl.IsKeyDown(.W) {
		mx += fx_mul(dx, speed)
		my += fx_mul(dy, speed)
	}
	if rl.IsKeyDown(.S) {
		mx -= fx_mul(dx, speed)
		my -= fx_mul(dy, speed)
	}
	if rl.IsKeyDown(.D) {
		mx -= fx_mul(dy, speed)
		my += fx_mul(dx, speed)
	}
	if rl.IsKeyDown(.A) {
		mx += fx_mul(dy, speed)
		my -= fx_mul(dx, speed)
	}

	if noclip {
		// Stay inside map bounds, but ignore walls.
		player.x = clamp(player.x + mx, 0, fx_from_int(MAP_W) - 1)
		player.y = clamp(player.y + my, 0, fx_from_int(MAP_H) - 1)
	} else {
		try_move(player, mx, my)
	}
}

render_view :: proc(fb: ^Framebuffer, player: ^Player) {
	dir_x := fx_cos(player.angle)
	dir_y := fx_sin(player.angle)
	// The camera plane is perpindicular to the view direction.
	plane_x := fx_mul(-dir_y, PLANE_SCALE)
	plane_y := fx_mul(dir_x, PLANE_SCALE)

	draw_floor_ceiling(fb, player, dir_x, dir_y, plane_x, plane_y)

	for x in 0 ..< VIEW_W {
		cam := column_x[x]
		ray_x := dir_x + fx_mul(plane_x, cam)
		ray_y := dir_y + fx_mul(plane_y, cam)

		delta_x := ray_delta(ray_x)
		delta_y := ray_delta(ray_y)

		map_x := fx_to_int(player.x)
		map_y := fx_to_int(player.y)

		// Distance from the player to the first vertical / horizontal grid line.
		step_x, step_y: int
		side_x, side_y: Fixed
		if ray_x < 0 {
			step_x = -1
			side_x = fx_mul(player.x - fx_from_int(map_x), delta_x)
		} else {
			step_x = 1
			side_x = fx_mul(fx_from_int(map_x + 1) - player.x, delta_x)
		}
		if ray_y < 0 {
			step_y = -1
			side_y = fx_mul(player.y - fx_from_int(map_y), delta_y)
		} else {
			step_y = 1
			side_y = fx_mul(fx_from_int(map_y + 1) - player.y, delta_y)
		}

		// DDA LOOP
		side := 0 // 0 = hit a vertical line (x side), 1 = horizontal (y side)
		for map_at(map_x, map_y) == 0 {
			if side_x < side_y {
				side_x += delta_x
				map_x += step_x
				side = 0
			} else {
				side_y += delta_y
				map_y += step_y
				side = 1
			}
		}
		tile := map_at(map_x, map_y)

		// Perpendicular distance (no fisheye, since rays come from a plane)
		perp := side_x - delta_x if side == 0 else side_y - delta_y
		perp = max(perp, MIN_DIST)

		// Where along the wall did we hit? The fraction picks the texture column.
		wall: Fixed
		if side == 0 {
			wall = player.y + fx_mul(perp, ray_y)
		} else {
			wall = player.x + fx_mul(perp, ray_x)
		}
		tex_x := (int(wall) & 0xFFFF) >> 10 // 16 bit fraction -> 0..63
		if (side == 0 && ray_x > 0) || (side == 1 && ray_y < 0) {
			tex_x = TEX_SIZE - 1 - tex_x // un-mirror textures on these faces
		}

		line_h := max(fx_to_int(fx_div(fx_from_int(PROJ_DIST), perp)), 1)
		draw_start := VIEW_H / 2 - line_h / 2

		// Step through the texture in 16.16 as we walk down the screen.
		step := (TEX_SIZE << FIXED_SHIFT) / line_h
		tex_pos := 0
		y0 := draw_start
		if y0 < 0 {
			tex_pos = -y0 * step // skip the texture rows that are off-screen
			y0 = 0
		}
		y1 := min(draw_start + line_h, VIEW_H)

		// Lighting is per-column: torch by distance, point lights at the hit point.
		hit_x := player.x + fx_mul(perp, ray_x)
		hit_y := player.y + fx_mul(perp, ray_y)
		b := AMBIENT + torch_light(perp) + light_at(hit_x, hit_y) - side * 3
		lm := &colormap[level_for(b)]

		tex := &textures[tile]
		for y in y0 ..< y1 {
			tex_y := (tex_pos >> FIXED_SHIFT) & (TEX_SIZE - 1)
			tex_pos += step
			fb[y * SCREEN_W + x] = lm[tex[tex_y * TEX_SIZE + tex_x]]
		}
	}
}
