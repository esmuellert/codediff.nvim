# Async Diff Implementation Architecture

## Overview

This document explains how async diff computation will be implemented to prevent UI blocking during large file diffs.

## Problem Statement

Current implementation is synchronous:
- `compute_diff()` blocks Lua thread for 1000-2000ms on large files
- User cannot type, move cursor, or interact during computation
- UI appears frozen

## Solution Architecture

Use multi-threading with event loop integration to compute diffs asynchronously without blocking the UI.

---

## Component Architecture

### 1. Threading Model

**Two threads:**
- **Main Thread (Lua Thread)**: Runs Neovim's event loop, handles UI, user input, rendering
- **Worker Thread**: Computes diff in parallel, pure C computation

**Key principle:** Worker thread never touches Lua - only computes diff and signals completion.

---

### 2. Event Loop Integration

**Neovim already has a running event loop (libuv):**
- Monitors keyboard input, mouse events, timers, file changes, network, etc.
- We add one more event: worker completion signal

**How it works:**
1. Main thread spawns worker, registers completion event with existing event loop
2. Main thread continues processing all events (keyboard, mouse, timers, etc.)
3. Worker computes diff in parallel
4. Worker signals completion via pipe
5. OS wakes main thread from event loop
6. Main thread handles worker completion like any other event

**Why UI stays responsive:**
- Main thread is not waiting specifically for worker
- Event loop handles ALL events: keyboard, worker signal, timers, etc.
- When user types during diff computation, event loop handles it immediately
- Worker signal is just one more event in the queue

---

### 3. Communication Mechanism

**Use OS primitives (pipe) for thread communication:**

**Setup:**
- Create a pipe (OS primitive)
- Add pipe to Neovim's event loop (via libuv)
- Main thread sleeps efficiently in `epoll_wait()` / `kqueue()` / IOCP

**Signaling:**
- Worker writes to pipe when done
- OS kernel detects pipe has data
- OS wakes main thread from event loop
- Main thread reads pipe, calls Lua callback

**Why pipe:**
- OS primitive with kernel support
- Thread-safe
- Can be monitored by epoll/kqueue/IOCP
- Instant wakeup (no polling)
- Zero CPU usage while waiting

---

### 4. Why libuv is Required

**Cannot use native threads alone:**
- Neovim's event loop IS libuv (`uv_run()`)
- Only one event loop can run per thread
- Must add our events to existing libuv loop
- Cannot create separate event loop

**Why not native pthread/Windows threads:**
- Even with native threads, need to integrate with Neovim's event loop
- Would still need libuv APIs to add pipe to event loop
- Would end up calling `uv_poll_init()` anyway
- Writing 3 OS-specific versions (epoll/kqueue/IOCP) that still can't integrate

**libuv provides:**
- Cross-platform thread API (`uv_thread_create`)
- Cross-platform async signaling (`uv_async_send`)
- Automatic integration with Neovim's event loop
- Already available (Neovim is built on libuv)

**Critical API:**
- `uv_default_loop()` - Returns Neovim's event loop
- `uv_async_init(uv_default_loop(), ...)` - Registers event with Neovim's loop
- `uv_async_send()` - Signals from worker thread

---

### 5. FFI + libuv Integration

**Two technologies work together:**

**FFI (Foreign Function Interface):**
- How Lua calls C functions
- `ffi.load('libvscode_diff')` loads our C library
- `lib.compute_diff_async(...)` calls C function

**libuv:**
- How C code integrates with Neovim's event loop
- Inside C code, use libuv APIs to spawn threads and signal completion
- `uv_async_init()`, `uv_thread_create()`, `uv_async_send()`

**Flow:**
```
Lua code
  ↓ (FFI)
C function: compute_diff_async()
  ↓ (libuv)
Neovim's event loop
```

---

## Implementation Components

### Lua Side (lua/vscode-diff/diff.lua)

**Responsibilities:**
- Store Lua callbacks (cannot pass directly to C)
- Call C async function via FFI
- Provide callback dispatcher for C to call back

**Changes needed:**
- Add callback registry (table mapping ID → callback)
- Add async API: `M.diff_async(orig, mod, callback)`
- Add internal callback dispatcher: `M._on_diff_complete(id, result)`

---

### C Side (libvscode-diff/async.c - new file)

**Responsibilities:**
- Receive async diff request from Lua
- Create worker thread
- Register with event loop
- Signal completion

**Key functions:**
- `compute_diff_async()`: Entry point, spawns worker, registers with event loop
- `worker_thread()`: Runs in worker thread, computes diff, signals
- `on_async_complete()`: Runs on main thread when signaled, calls back to Lua

**Critical libuv calls:**
- `uv_async_init(uv_default_loop(), &handle, callback)` - Register with event loop
- `uv_thread_create(&thread, worker_func, data)` - Spawn worker
- `uv_async_send(&handle)` - Signal from worker (thread-safe)
- `uv_thread_join(&thread)` - Cleanup worker thread
- `uv_close(&handle)` - Cleanup async handle

---

### Calling Flow

**User initiates diff:**
1. Lua: Store callback, generate ID
2. Lua: Call `lib.compute_diff_async(orig, mod, id)` via FFI
3. C: Copy string data (worker will need it)
4. C: Create async handle: `uv_async_init(uv_default_loop(), ...)`
5. C: Spawn worker: `uv_thread_create(...)`
6. C: Return immediately to Lua

**Worker computes:**
7. Worker: Call `compute_diff(orig, mod)` (existing sync code)
8. Worker: Signal completion: `uv_async_send(handle)`
9. Worker: Exit

**Main thread callback:**
10. OS: Detects pipe signal, wakes main thread
11. libuv: Calls our C callback (on main thread)
12. C: Join worker thread
13. C: Call Lua dispatcher: `M._on_diff_complete(id, result)`
14. Lua: Look up callback by ID
15. Lua: Call user's callback with result
16. Lua: Apply highlights, open buffers, etc.

---

## Key Design Decisions

**Why not vim.schedule():**
- Still blocks during computation
- Just defers the blocking, doesn't eliminate it
- Not true async

**Why not vim.system() (spawn process):**
- Slower (process overhead)
- Complex data serialization
- Still async, but less efficient than threads

**Why threads + libuv:**
- True async (no blocking)
- Efficient (shared memory, no serialization)
- Integrates with Neovim's architecture

**Memory safety:**
- Copy all string data before passing to worker
- Worker owns copies, frees them
- Main thread never touches worker's data during computation
- After join, safe to access result

---

## Performance Impact

**Current (sync):**
- Large file: 1000-2000ms blocked
- UI frozen during computation

**After async:**
- Worker spawn: <1ms
- Main thread: continues immediately
- UI: fully responsive
- Callback: <1ms after worker completes

**User experience:**
- Opens tabs immediately (empty)
- User can type, navigate during computation
- Highlights appear when ready (1-2s later)
- No perceived freeze

---

## Summary

**Architecture:**
- Main thread (Lua) + Worker thread (C)
- Communication via libuv async handles (pipes)
- Integration with Neovim's existing event loop

**Technologies:**
- FFI: Lua ↔ C communication
- libuv: Thread management + event loop integration
- OS primitives: Pipes for signaling

**Result:**
- Non-blocking diff computation
- Responsive UI during heavy operations
- Seamless integration with Neovim's architecture
