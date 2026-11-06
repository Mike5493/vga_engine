package main

import "core:mem"

//odinfmt:disable
PERM_SIZE  :: 2 * mem.Megabyte   // everything that lives for the whole run
FRAME_SIZE :: 64 * mem.Kilobyte  // scratch, emptied every frame

TRACK_MEMORY :: #config(TRACK_MEMORY, true) // build with -define:TRACK_MEMORY=false to strip it

perm_buf:    [PERM_SIZE]byte
frame_buf:   [FRAME_SIZE]byte
perm_arena:  mem.Arena
frame_arena: mem.Arena
//odinfmt:enable

tracker: ^mem.Tracking_Allocator // nil unless tracking is on

init_memory :: proc() {
	mem.arena_init(&perm_arena, perm_buf[:])
	mem.arena_init(&frame_arena, frame_buf[:])
}
