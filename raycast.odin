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
CROUCH_EYE    :: Fixed(16384)   // 0.25 tile: eye height when crouched
CROUCH_HEIGHT :: Fixed(22938)   // 0.35 tile: clearance needed when crouched
GRAVITY       :: Fixed(262)		// about 0.004 tile per frame^2
JUMP_SPEED	  :: Fixed(3709)    // launch speed, peaks around 0.4 tile
SNAP          :: Fixed(9830)    // 0.15 tile: stay glued to stairs and ramps going down

// Lighting
NUM_LEVELS  :: 32               // colormap rows: 0 = full bright, 31 = nearly black
AMBIENT     :: 3                // brightness everywhere, even far from any light
TORCH_FALL  :: 2                // torch brightness lost per tile of distance
LIGHT_FALL  :: 2                // point light brightness lost per tile squared
LIGHT_RANGE :: Fixed(8 << 16)

// Varying height constants
HEIGHT_SHIFT  :: 13               // heights are in 1/8 tile: raw << 13 = 16.16
EYE_HEIGHT    :: Fixed(32768)     // 0.5 tile above the floor
EYE_MARGIN    :: Fixed(6554)      // 0.1 tile: eye stays this far from floor and ceiling
PLAYER_HEIGHT :: Fixed(39322)     // 0.6 tile: ceiling must clear this to walk in
MAX_STEP      :: Fixed(16384)     // 0.25 tile: tallest step you can climb
RISER_TEX     :: 2                // stone for step faces
LINTEL_TEX    :: 1                // brick for low-ceiling drops
MAX_T         :: Fixed(255 << 16) // clamp for far-away floor hits
//odinfmt:enable

Texture :: [TEX_SIZE * TEX_SIZE]u8

Player :: struct {
	x, y:      Fixed,
	z:         Fixed, // eye height in the world
	feet:      Fixed,
	vz:        Fixed, // vertial velocity
	crouching: bool,
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

Plane :: struct {
	z0:     Fixed, // floor height at the cell's top-left corner
	gx, gy: Fixed, // height gained per tile in x and y
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

// Floor heights, 1/8 tile per digit. Stairs on the east side, a too-tall bench on row 5.
floor_src := [MAP_H]string{
	"0000000000000000",
	"0000000000000000",
	"0000000000000000",
	"0000000000000000",
	"0000000000000000",
	"0000000003300000",
	"0000000000000000",
	"0024666600000000",
	"0000000000000000",
	"0000000000012340",
	"0000000000002340",
	"0000000000012340",
	"0000000000000000",
	"0000000000000000",
	"0000000000002220",
	"0000000000000000",
}

// Direction the floor rises toward: e/w/n/s = 0.25 tile, E/W/N/S = 0.5 tile.
slope_src := [MAP_H]string{
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	".eee............",
	"................",
	"................",
	"................",
	"................",
	"................",
	"............sss.",
	"................",
	"................",
}

// Ceiling heights: 0-9 then a=10, b=11, c=12... '8' is the old 1-tile room.
ceil_src := [MAP_H]string{
	"8888888888888888",
	"8888888866666688",
	"8888888888888888",
	"8888888888888888",
	"8888888888888888",
	"8888888888888888",
	"8888888888888888",
	"8888888888888888",
	"8888888888888888",
	"8888888888888cc8",
	"8888888888888cc8",
	"8888888888888cc8",
	"8888888888888888",
	"8888888888888888",
	"8888444888888888",
	"8888888888888888",
}

// Globals
world_map:  [MAP_H][MAP_W]u8
textures:   [NUM_TEXTURES]Texture
column_x:   [VIEW_W]Fixed            // camera-plane position of each column, -1..+1
floor_h:    [MAP_H][MAP_W]u8
ceil_h:     [MAP_H][MAP_W]u8
colormap:   [NUM_LEVELS][256]u8
floor_plane: [MAP_H][MAP_W]Plane
noclip:     bool
mouse_look: bool = true
torch_power := 26                    // brightness at the player, 0..31 ([ and ] change it)
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

	for y in 0 ..< MAP_H {
		for x in 0 ..< MAP_W {
			ceil_h[y][x] = parse_height(ceil_src[y][x])

			low := Fixed(int(parse_height(floor_src[y][x])) << HEIGHT_SHIFT)
			c := slope_src[y][x]

			rise := 0
			switch c {
			case 'e', 'w', 'n', 's':
				rise = 2
			case 'E', 'W', 'N', 'S':
				rise = 4
			}
			g := Fixed(rise << HEIGHT_SHIFT)

			p := Plane {
				z0 = low,
			}
			switch c {
			case 'e', 'E':
				p.gx = g
			case 'w', 'W':
				p.z0 = low + g; p.gx = -g
			case 's', 'S':
				p.gy = g
			case 'n', 'N':
				p.z0 = low + g; p.gy = -g
			}
			floor_plane[y][x] = p
		}
	}

	// Pixel-center camera positions, so the view is symetric.
	for x in 0 ..< VIEW_W {
		column_x[x] = Fixed(((2 * x + 1 - VIEW_W) << FIXED_SHIFT) / VIEW_W)
	}
}

// Screen row where world height z appears at distance t, seen from eye height eye.
proj_y :: proc(z, eye, t: Fixed) -> int {
	return VIEW_H / 2 - (int(z - eye) * PROJ_DIST) / int(max(t, MIN_DIST))
}

// A vertical run of wall pixels. Texture rows come from world height,
// so textures stay anchored across steps.
draw_wall :: proc(
	fb: ^Framebuffer,
	x, y0, y1: int,
	tile: u8,
	tex_x: int,
	t, eye: Fixed,
	lm: ^[256]u8,
) {
	tex := &textures[tile]
	for y in y0 ..< y1 {
		z := int(eye) - ((2 * y + 1 - VIEW_H) * int(t)) / (2 * PROJ_DIST)
		tex_y := ((int(FIXED_ONE) - z) >> 10) & (TEX_SIZE - 1)
		fb[y * SCREEN_W + x] = lm[tex[tex_y * TEX_SIZE + tex_x]]
	}
}

// A vertical run of floor or ceiling pixels. h is the height difference from the
// eye; each row's distance follows from it, and the distance gives the world
// position for texturing and lighting.
draw_span :: proc(
	fb: ^Framebuffer,
	player: ^Player,
	x: int,
	ray_x, ray_y: Fixed,
	y0, y1: int,
	h: Fixed,
	ceiling: bool,
) {
	tex := &textures[TEX_CEIL if ceiling else TEX_FLOOR]
	for y in y0 ..< y1 {
		dy2 := (VIEW_H - 2 * y - 1) if ceiling else (2 * y - VIEW_H + 1)
		if dy2 < 1 do continue

		t := Fixed((int(h) * 2 * PROJ_DIST) / dy2)
		wx := player.x + fx_mul(t, ray_x)
		wy := player.y + fx_mul(t, ray_y)
		tx := (int(wx) >> 10) & (TEX_SIZE - 1)
		ty := (int(wy) >> 10) & (TEX_SIZE - 1)

		lm := &colormap[level_for(AMBIENT + torch_light(t) + light_at(wx, wy))]
		fb[y * SCREEN_W + x] = lm[tex[ty * TEX_SIZE + tx]]
	}
}

// A vertical run of floor pixels on cell (cx, cy)'s floor plane, which may slope.
draw_floor_span :: proc(
	fb: ^Framebuffer,
	player: ^Player,
	x: int,
	ray_x, ray_y: Fixed,
	cx, cy, y0, y1: int,
	eye: Fixed,
) {
	tex := &textures[TEX_FLOOR]
	p := &floor_plane[cy][cx]

	// Eye height above this plane (measured under the player), and how fast the
	// plane rises per unit of distance along this particular ray.
	under :=
		p.z0 + fx_mul(p.gx, player.x - fx_from_int(cx)) + fx_mul(p.gy, player.y - fx_from_int(cy))
	base := int(eye - under)
	grad := int(fx_mul(p.gx, ray_x) + fx_mul(p.gy, ray_y))

	for y in y0 ..< y1 {
		m := ((2 * y - VIEW_H + 1) * 32768) / PROJ_DIST // view ray slope for this row, 16.16
		den := max(m + grad, 1)
		t := Fixed(clamp((base << FIXED_SHIFT) / den, 0, int(MAX_T)))

		wx := player.x + fx_mul(t, ray_x)
		wy := player.y + fx_mul(t, ray_y)
		tx := (int(wx) >> 10) & (TEX_SIZE - 1)
		ty := (int(wy) >> 10) & (TEX_SIZE - 1)

		lm := &colormap[level_for(AMBIENT + torch_light(t) + light_at(wx, wy))]
		fb[y * SCREEN_W + x] = lm[tex[ty * TEX_SIZE + tx]]
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
		if abs(dx) > LIGHT_RANGE || abs(dy) > LIGHT_RANGE do continue

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

// Height helpers
parse_height :: proc(c: u8) -> u8 {
	if c >= 'a' do return c - 'a' + 10
	return c - '0'
}


cell_ceil :: proc(x, y: int) -> Fixed {
	if x < 0 || x >= MAP_W || y < 0 || y >= MAP_H do return Fixed(8 << HEIGHT_SHIFT)
	return Fixed(int(ceil_h[y][x]) << HEIGHT_SHIFT)
}

// Floor height at a world position, using the plane of call (cx, cy).
floor_z :: proc(cx, cy: int, wx, wy: Fixed) -> Fixed {
	if cx < 0 || cx >= MAP_W || cy < 0 || cy >= MAP_H do return 0
	p := &floor_plane[cy][cx]
	return p.z0 + fx_mul(p.gx, wx - fx_from_int(cx)) + fx_mul(p.gy, wy - fx_from_int(cy))
}

// Can the player stand at this world position, coming from 'from_floor'?
walkable :: proc(wx, wy: Fixed, feet, height: Fixed) -> bool {
	cx := fx_to_int(wx)
	cy := fx_to_int(wy)
	if map_at(cx, cy) != 0 do return false
	f := floor_z(cx, cy, wx, wy)
	c := cell_ceil(cx, cy)
	return f - feet <= MAX_STEP && c - max(f, feet) >= height
}

try_move :: proc(player: ^Player, dx, dy, height: Fixed) {
	// Test each axis separately so we can wall slide!
	new_x := player.x + dx
	probe_x := new_x + (PLAYER_RADIUS if dx > 0 else -PLAYER_RADIUS)
	if walkable(probe_x, player.y, player.feet, height) {
		player.x = new_x
	}

	new_y := player.y + dy
	probe_y := new_y + (PLAYER_RADIUS if dy > 0 else -PLAYER_RADIUS)
	if walkable(player.x, probe_y, player.feet, height) {
		player.y = new_y
	}
}

update_player :: proc(player: ^Player) {
	// Toggles
	if rl.IsKeyPressed(.F3) do debug_on = !debug_on
	if rl.IsKeyPressed(.F4) do crosshair_on = !crosshair_on
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

	// Ease the eye toward floor + EYE_HEIGHT, but never through floor or ceiling.
	cx := fx_to_int(player.x)
	cy := fx_to_int(player.y)
	ground := floor_z(cx, cy, player.x, player.y)
	cell_c := cell_ceil(cx, cy)

	// Crouch (C or Left Ctrl). Releasing only stands player up if there's headroom.
	if rl.IsKeyDown(.C) || rl.IsKeyDown(.LEFT_CONTROL) {
		player.crouching = true
	} else if player.crouching && cell_c - player.feet >= PLAYER_HEIGHT {
		player.crouching = false
	}
	height := CROUCH_HEIGHT if player.crouching else PLAYER_HEIGHT

	// Jump (Space), from the ground only, and not while crouched.
	if rl.IsKeyPressed(.SPACE) && player.feet <= ground && !player.crouching {
		player.vz = JUMP_SPEED
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
		try_move(player, mx, my, height)
	}

	// Vertical: read the floor and ceiling under the new position.
	cx = fx_to_int(player.x)
	cy = fx_to_int(player.y)
	ground = floor_z(cx, cy, player.x, player.y)
	cell_c = cell_ceil(cx, cy)

	if player.vz <= 0 && player.feet - ground <= SNAP {
		player.feet = ground // glued to floor (stairs, ramps, landing)
		player.vz = 0
	} else {
		player.vz -= GRAVITY
		player.feet += player.vz
		if player.feet <= ground {
			player.feet = ground
			player.vz = 0
		}
	}

	// Bonk your head on the ceiling.
	if player.feet + height > cell_c {
		player.feet = cell_c - height
		if player.vz > 0 do player.vz = 0
	}

	// Eye: smooth when grounded (stairs, crouching), exact while airborne.
	target := player.feet + (CROUCH_EYE if player.crouching else EYE_HEIGHT)
	airborne := player.vz != 0 || player.feet - ground > SNAP
	if airborne {
		player.z = target
	} else {
		player.z += (target - player.z) / 4
	}
	player.z = clamp(player.z, ground + EYE_MARGIN, cell_c - EYE_MARGIN)
}

render_view :: proc(fb: ^Framebuffer, player: ^Player) {
	dir_x := fx_cos(player.angle)
	dir_y := fx_sin(player.angle)
	// The camera plane is perpindicular to the view direction.
	plane_x := fx_mul(-dir_y, PLANE_SCALE)
	plane_y := fx_mul(dir_x, PLANE_SCALE)
	eye := player.z

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

		f_near := floor_z(map_x, map_y, player.x, player.y) // floor height where the ray enters this cell
		cur_c := cell_ceil(map_x, map_y)
		y_top := 0          // rows above this are done
		y_bot := VIEW_H     // rows from here down are done
		t_enter := Fixed(0) // distance where the ray entered the current cell

		for y_top < y_bot {
			cx, cy := map_x, map_y // the cell we're leaving

			// Next grid line crossing: the far edge of the cell we're in.
			side := 0
			t_exit: Fixed
			if side_x < side_y {
				t_exit = side_x
				side_x += delta_x
				map_x += step_x
			} else {
				t_exit = side_y
				side_y += delta_y
				map_y += step_y
				side = 1
			}
			t_wall := max(t_exit, MIN_DIST)

			hit_x := player.x + fx_mul(t_wall, ray_x)
			hit_y := player.y + fx_mul(t_wall, ray_y)

			// Floor of the cell we just crossed(may slope, so its far edge has its own height).
			f_far := floor_z(cx, cy, hit_x, hit_y)
			y_far := proj_y(f_far, eye, t_wall)
			y_near := proj_y(f_near, eye, t_enter)
			draw_floor_span(
				fb,
				player,
				x,
				ray_x,
				ray_y,
				cx,
				cy,
				max(y_far, y_top),
				min(y_near, y_bot),
				eye,
			)
			y_bot = min(y_bot, y_far)

			// Ceiling of the cell we just crossed.
			c_far := proj_y(cur_c, eye, t_wall)
			c_near := proj_y(cur_c, eye, t_enter)
			draw_span(
				fb,
				player,
				x,
				ray_x,
				ray_y,
				max(c_near, y_top),
				min(c_far, y_bot),
				cur_c - eye,
				true,
			)
			y_top = max(y_top, c_far)

			// Wall geometry at this grid line: texture column and lighting.
			wall_pos := hit_y if side == 0 else hit_x
			tex_x := (int(wall_pos) >> 10) & (TEX_SIZE - 1)
			if (side == 0 && ray_x > 0) || (side == 1 && ray_y < 0) {
				tex_x = TEX_SIZE - 1 - tex_x // un-mirror textures on these faces
			}
			lm := &colormap[level_for(AMBIENT + torch_light(t_wall) + light_at(hit_x, hit_y) - side * 3)]

			tile := map_at(map_x, map_y)
			if tile != 0 {
				draw_wall(fb, x, y_top, y_bot, tile, tex_x, t_wall, eye, lm)
				break
			}

			// Open neighbor: show any step up (riser) or ceiling drop (lintel).
			next_f := floor_z(map_x, map_y, hit_x, hit_y)
			next_c := cell_ceil(map_x, map_y)

			if next_f > f_far {
				r_top := proj_y(next_f, eye, t_wall)
				draw_wall(fb, x, max(r_top, y_top), y_bot, RISER_TEX, tex_x, t_wall, eye, lm)
				y_bot = min(y_bot, r_top)
			}
			if next_c < cur_c {
				l_bot := proj_y(next_c, eye, t_wall)
				draw_wall(fb, x, y_top, min(l_bot, y_bot), LINTEL_TEX, tex_x, t_wall, eye, lm)
				y_top = max(y_top, l_bot)
			}

			f_near = next_f
			cur_c = next_c
			t_enter = t_wall
		}
	}
}
