# Dev journal — opencode-nix-sandbox

Append-only. Newest at the bottom.

## 2026-06-25 — Milestone 1: bubblewrap backend

**Goal:** nix-native sandbox for the opencode TUI, mirroring the bubblewrap
backend of `jhhuh/claude-code-nix-sandbox`.

**Design decisions (see `docs/plans/2026-06-25-opencode-bubblewrap-sandbox-design.md`):**
- Bubblewrap backend only this milestone (nspawn/VM/manager/CLI/NixOS modules deferred).
- No Chromium / X11 / Wayland / D-Bus / GPU / audio / keyring — opencode is a
  terminal TUI, so all of the reference's browser+display machinery was dropped.
- opencode from nixpkgs (`pkgs.opencode`); resolved to **1.17.7** on the pinned
  nixos-unstable (the `nix eval` against the host flake registry showed 1.1.14,
  but the flake's own pin builds 1.17.7).
- Auth/config persistence via RW bind-mounts of `~/.local/share/opencode` and
  `~/.config/opencode`.
- Provider keys: curated set forwarded if present, plus
  `OPENCODE_SANDBOX_FORWARD_ENV` override.

**Implementation:** `flake.nix`, `nix/sandbox-spec.nix`,
`nix/backends/bubblewrap.nix` (writeShellApplication wrapping bwrap). Packages:
`default` (wrapper + bundled opencode), `sandbox`, `no-network`.

**Review outcome (subagent-driven, two-stage):**
- Spec review: ✅ exact match, nothing extra.
- Code-quality review: happy path approved. Flagged that gh/ssh always-mounted,
  daemon-socket-in-no-network, and no `$HOME` guard are real tradeoffs — but all
  three are faithful parity with the claude reference. User chose **keep full
  parity**; only fixed the `realpath` nit (`realpath -m`) so an invalid
  `<project-dir>` hits the friendly error under `set -e` instead of aborting.

**Verification (all passed):**
- `nix flake check` + `nix build .#sandbox` succeed.
- Isolation: project dir RW and persists to host; `$HOME` is an isolated tmpfs;
  host home not visible; ephemeral HOME writes don't leak.
- Config: data/config dirs mounted RW; a write to `~/.config/opencode` inside
  the sandbox lands on the host.
- Network: default sandbox resolves+connects to `github.com:443` and
  `api.anthropic.com:443` (getaddrinfo via bash `/dev/tcp`); `no-network`
  blocks both.
- opencode executes inside bwrap: `--version` → 1.17.7, `--help` lists commands.

**Gotchas discovered:**
- `--shell` entrypoint is a bare interactive `bash` and does NOT forward trailing
  args (matches reference). To script it, pipe via stdin:
  `echo 'cmds' | opencode-sandbox --shell <dir>`. The plan's `--shell ... -c`
  test silently ran nothing.
- `getent` is not in the sandbox package set, so the plan's `getent hosts` DNS
  test returned rc=127 (looked like a DNS failure but wasn't). Use
  getaddrinfo-based checks (`bash /dev/tcp/host/port`) instead. DNS itself works
  fine — `/etc/resolv.conf` + `nsswitch.conf` are forwarded.

**Commits (branch `feat/bubblewrap-backend`):**
- design doc, implementation plan
- `Add bubblewrap backend, sandbox spec, and flake`
- `Use realpath -m so invalid project-dir hits friendly error under set -e`
