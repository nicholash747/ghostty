//! Manual I/O backend for embedding scenarios where the host feeds
//! terminal output bytes directly (e.g., from an SSH transport).
//!
//! No child process or PTY is created. The host application:
//!   1. Feeds output via ghostty_surface_feed_terminal_output()
//!      which calls Termio.processOutput() directly.
//!   2. Reads terminal responses (e.g., cursor position reports)
//!      via ghostty_surface_read_terminal_input() which drains
//!      the input ring buffer populated by queueWrite().
const Manual = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

const log = std.log.scoped(.io_manual);

/// Ring buffer capacity for terminal responses flowing back to host.
const RING_CAPACITY = 16384;

/// Configuration for the manual backend (currently empty).
pub const Config = struct {};

/// Thread data for the manual backend (minimal — no PTY state).
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};

// ── Ring buffer ──────────────────────────────────────────────────

const RingBuffer = struct {
    buf: [RING_CAPACITY]u8,
    read_pos: usize,
    write_pos: usize,

    fn init() RingBuffer {
        return .{
            .buf = undefined,
            .read_pos = 0,
            .write_pos = 0,
        };
    }

    /// Write as many bytes as fit. Returns count written.
    fn write(self: *RingBuffer, data: []const u8) usize {
        var written: usize = 0;
        for (data) |byte| {
            const next = (self.write_pos + 1) % RING_CAPACITY;
            if (next == self.read_pos) break; // full
            self.buf[self.write_pos] = byte;
            self.write_pos = next;
            written += 1;
        }
        return written;
    }

    /// Read available bytes into `out`. Returns count read.
    fn read(self: *RingBuffer, out: []u8) usize {
        var count: usize = 0;
        while (count < out.len and self.read_pos != self.write_pos) {
            out[count] = self.buf[self.read_pos];
            self.read_pos = (self.read_pos + 1) % RING_CAPACITY;
            count += 1;
        }
        return count;
    }
};

// ── State ────────────────────────────────────────────────────────

/// Ring buffer for terminal responses (queueWrite → host read).
input_ring: RingBuffer,

/// Protects input_ring across threads.
mutex: std.Thread.Mutex,

// ── Backend interface ────────────────────────────────────────────

pub fn init(alloc: Allocator, cfg: Config) !Manual {
    _ = alloc;
    _ = cfg;
    return .{
        .input_ring = RingBuffer.init(),
        .mutex = .{},
    };
}

pub fn deinit(self: *Manual) void {
    _ = self;
}

pub fn initTerminal(self: *Manual, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
}

pub fn threadEnter(
    self: *Manual,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .manual = .{} };
}

pub fn threadExit(self: *Manual, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *Manual,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Manual,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = self;
    _ = grid_size;
    _ = screen_size;
}

pub fn queueWrite(
    self: *Manual,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;
    _ = linefeed;

    self.mutex.lock();
    defer self.mutex.unlock();
    const written = self.input_ring.write(data);
    if (written < data.len) {
        log.warn("manual input ring full, dropped {} bytes", .{data.len - written});
    }
}

pub fn childExitedAbnormally(
    self: *Manual,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

// ── Host-facing API ──────────────────────────────────────────────

/// Read terminal responses (input flowing back to host).
/// Called by ghostty_surface_read_terminal_input().
pub fn readInput(self: *Manual, out: []u8) usize {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.input_ring.read(out);
}
