# opencode-nix-sandbox — Bubblewrap backend design

**Date:** 2026-06-25
**Status:** Approved (milestone 1)
**Reference:** `github.com/jhhuh/claude-code-nix-sandbox`

## Goal

Pure-Nix machinery to run sandboxed [opencode](https://github.com/sst/opencode)
(a terminal TUI coding agent) sessions, mirroring the structure of the author's
`claude-code-nix-sandbox`. Milestone 1 delivers the **bubblewrap** (unprivileged)
backend only; systemd-nspawn, QEMU VM, the Rust manager, dashboard, CLI, and
NixOS modules are deferred.

## Decisions

- **Scope:** bubblewrap backend only for milestone 1.
- **No Chromium:** opencode is a terminal TUI and does not drive a browser, so
  the reference's `chromium.nix`, extension policy, and the X11 / Wayland /
  D-Bus / GPU / audio / keyring forwarding are all dropped.
- **Package source:** `pkgs.opencode` from the pinned nixpkgs (opencode ships in
  nixpkgs; no separate flake input like the claude repo needed for
  `sadjow/claude-code-nix`). Bump nixpkgs to update opencode.
- **Auth & config:** bind-mount `~/.local/share/opencode` and
  `~/.config/opencode` read-write for persistence (created if absent).
  opencode's `auth.json` (from `opencode auth login`) lives under
  `~/.local/share/opencode`.
- **Provider keys:** forward a curated default set if present, plus an override
  env var for extra names.
- **Layout:** mirror the reference (approach A) so later backends slot in
  without restructuring.

## Layout

```
flake.nix
nix/sandbox-spec.nix          # packages list + host /etc paths to bind
nix/backends/bubblewrap.nix   # writeShellApplication wrapping bwrap
flake.lock
README.md
artifacts/                    # plan_*.md + devlog.md (author CLAUDE.md workflow)
docs/plans/                   # this design doc
```

## flake.nix

- **Inputs:** `nixpkgs` (nixos-unstable) only.
- **Systems:** `x86_64-linux`, `aarch64-linux`.
- **Packages:**
  - `default` = `symlinkJoin` of the bubblewrap wrapper + `opencode`, so both
    `opencode-sandbox` and `opencode` land on PATH at a matched version.
  - `sandbox` = wrapper only.
  - `no-network` = wrapper built with `network = false` (`--unshare-net`).
- **devShells.default:** `nixd`, `nil`, `nixpkgs-fmt`.
- **checks:** the three packages build.

## nix/sandbox-spec.nix

Single source of truth for:
- `packages`: base runtime tools available inside the sandbox (bash, coreutils,
  git, openssh, gh, cacert, and opencode's own runtime deps as needed).
- `hostEtcPaths`: host `/etc` files to bind read-only (e.g. `resolv.conf`,
  `ssl/certs`, `nsswitch.conf`, `hosts`, `localtime`).

## nix/backends/bubblewrap.nix

`writeShellApplication` named `opencode-sandbox`.

**Usage:** `opencode-sandbox [--shell] [--gh-token] <project-dir> [opencode args...]`

**Parameters:** `network ? true`, `extraPackages ? []`.

**What the wrapper does:**
- Resolves and validates `<project-dir>`; binds it read-write and `--chdir` into it.
- `--tmpfs /home` then `--dir $HOME`; binds `~/.local/share/opencode` and
  `~/.config/opencode` read-write (mkdir on host first).
- Read-only forwarding: `~/.gitconfig`, `~/.config/git`, `~/.ssh`,
  `SSH_AUTH_SOCK`, `~/.config/gh`.
- Nix daemon: `/nix/store` ro, `/nix/var/nix/db` ro, daemon socket bind,
  `NIX_REMOTE=daemon`, `/run/current-system/sw` ro-try.
- `/etc` paths from `sandbox-spec.nix` (ro).
- `/bin/sh` + `/bin/bash` + `/usr/bin/bash` symlinks to the sandbox bash;
  `/usr/bin/env` ro-try.
- Curated provider-key env forwarding when set: `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`,
  `GOOGLE_GENERATIVE_AI_API_KEY`, `GROQ_API_KEY`. Extra names via
  `OPENCODE_SANDBOX_FORWARD_ENV` (space-separated).
- TUI essentials: `TERM` (default `xterm-256color`), `LANG`, `LC_ALL`.
- `--gh-token` forwards `GH_TOKEN` / `GITHUB_TOKEN`.
- `--shell` selects `bash` as entrypoint instead of `opencode "$@"`.
- `--die-with-parent`, `--proc /proc`, `--dev /dev`, `--dev-bind /dev/shm`,
  `--tmpfs /tmp`, `--tmpfs /run`.
- `network = false` adds `--unshare-net`.

**Deliberately omitted vs reference:** Chromium, X11/Wayland, D-Bus (system +
session), DRI/GPU, OpenGL drivers, PipeWire/PulseAudio, keyring, `--tmux` mode,
per-project chromium profile.

## Verification

- `nix flake check` (all packages build).
- `nix run .#sandbox -- --shell <dir>`: project dir writable, `$HOME` is tmpfs,
  `opencode` on PATH, git/ssh visible read-only.
- `nix run . -- <dir>`: launches the opencode TUI against a configured provider.
- `nix run .#no-network -- --shell <dir>`: confirm egress blocked (e.g. `curl`
  to an external host fails) while local project work still functions.

## Deferred (future milestones)

systemd-nspawn backend, QEMU VM backend, Rust/Axum manager daemon + htmx
dashboard, `opencode-remote` SSH CLI, NixOS modules, nixosTest suite, mdBook docs.
