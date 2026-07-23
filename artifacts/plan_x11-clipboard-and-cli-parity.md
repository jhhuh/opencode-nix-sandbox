# Plan — X11 clipboard forwarding + CLI ergonomics parity

Port two claude-code-nix-sandbox commits, adapted to opencode:
- `5c3c29c` (xclip for `/copy`) — **adapted**, not verbatim.
- `fbe41ca` (self-awareness notice + optional project-dir / `--`) — **partial**: CLI
  ergonomics + env vars only; skip `--append-system-prompt` (opencode has no such flag).

## Why the adaptation (opencode ≠ claude-code)

- opencode copies **text** via **OSC 52** (terminal escape) — needs no clipboard
  binary and no X11. Its only clipboard *binary* use is reading an `image/png`
  **from** the host clipboard (`xclip -selection clipboard` on X11, `wl-paste` on
  Wayland). So image-paste-from-host is the feature that needs xclip **plus** an X
  socket. User asked to bind the X socket and do the full packaging.
- opencode's TUI has no `--append-system-prompt`; injecting a notice cleanly would
  require `OPENCODE_CONFIG_CONTENT` gymnastics and its motivation (a headless agent
  probing host tools) is weak for interactive use. Env vars cover detection instead.

## Changes

### nix/sandbox-spec.nix
- Add `xclip` (X11) and `wl-clipboard` (Wayland) to `packages`, since we forward
  both sockets.

### nix/backends/bubblewrap.nix
1. X11 forwarding block (mirror reference): `x11_args` (tmpfs /tmp/.X11-unix +
   ro-bind the `/tmp/.X11-unix/X$n` socket), `xauth_args` (ro-bind `$XAUTHORITY`),
   `wayland_args` (ro-bind `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`).
2. setenv `DISPLAY` / `WAYLAND_DISPLAY` / `XAUTHORITY` when present.
3. Place `x11_args`/`xauth_args`/`wayland_args` in `exec bwrap` after the
   `/usr/bin/env` bind (i.e. after `--tmpfs /tmp` and `--tmpfs /run` so the nested
   binds land in the tmpfs).
4. CLI: optional `project_dir` (default `.`), `--` separator → `opencode_args`,
   `usage()` fn, unknown `-*` errors with a `use '--'` hint. Preserve `realpath -m`.
5. setenv `OPENCODE_SANDBOX=1`, `OPENCODE_SANDBOX_BACKEND=bubblewrap`.
6. Update the header usage comment.

## Verify
- `nix build .#sandbox` green; `nix build .#no-network` green.
- `--help` exits 0 with new usage; `--bogus` rejected; bare invocation defaults cwd.
- Inspect wrapper: `x11_args`/xclip/wl-clipboard present; `OPENCODE_SANDBOX*` setenv.
- Real round-trip (user-confirmed, needs their X session): inside `--shell`,
  `printf hi | xclip -selection clipboard && xclip -selection clipboard -o`.
