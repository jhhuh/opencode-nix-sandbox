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

## 2026-06-25 — CI + flake autoupdate

Mirrored the reference's GitHub Actions (`.github/workflows/`):
- `ci.yml` — builds `default`/`sandbox`/`no-network` on push/PR to `main`.
- `update-flake.yml` — daily (03:00 UTC) `nix flake update` → `nix build` →
  commit+push `flake.lock`. Keeps opencode current via nixpkgs bumps.

Deltas vs reference: dropped its "check upstream `sadjow/claude-code-nix`"
pre-step (we have no such input — nixpkgs is the only flake input, so we update
unconditionally); branch is `main` not `master`; no container/VM/docs jobs.
Validated with `actionlint` (rc=0, includes shellcheck of the embedded scripts).
Note: these only run once the repo is pushed to GitHub (no remote yet).

## 2026-06-26 — Switch opencode from nixpkgs to llm-agents.nix

The opencode from nixpkgs (1.17.7 on the pinned nixos-unstable) was reported
broken. Switched to `github:numtide/llm-agents.nix`, which provides opencode
via direct GitHub release binary download (v1.17.10, daily auto-updated).

Changes:
- Added `llm-agents` flake input, following nixpkgs.
- Applied `llm-agents.overlays.default` providing `pkgs.llm-agents.opencode`.
- Every `pkgs.opencode` reference replaced with `pkgs.llm-agents.opencode`:
  `flake.nix` (default symlinkJoin path), `nix/sandbox-spec.nix` (in-sandbox
  PATH package).
- `update-flake.yml` now keeps opencode current via llm-agents' daily lock
  updates instead of nixpkgs bumps.
- `nix flake check` passes; all three packages build with opencode 1.17.10.

## 2026-06-26 — Drop redundant curated env forwarding

bwrap runs without `--clearenv`, so the full host environment is inherited
into the sandbox. That means `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, and any
other provider vars already flow through transparently. The curated provider-key
`--setenv` loop and the `OPENCODE_SANDBOX_FORWARD_ENV` override were therefore
dead logic that implied an allowlist boundary the code never enforced. Removed
the loop; transparent inheritance is the documented contract now. Decision:
keep env pass-through transparent (no `--clearenv`) per user requirement.


## 2026-07-22 — Fix flake-update auto-update (jq bug + upstream overlay break)

The daily `update-flake.yml` had failed 25 runs straight (~10s each). Root
cause: `jq -r '.nodes.llm-agents.locked.rev'` parses the hyphen as
subtraction (`.nodes.llm` minus `agents`) → `jq: error: agents/0 is not
defined`. Fixed with bracket syntax `.nodes["llm-agents"]`.

With that fixed, a manual run got all the way to the build gate and caught a
*real* upstream break: newer `llm-agents.nix` dropped `overlays.default`
(now only `overlays.shared-nixpkgs`), so `pkgs.llm-agents.opencode` no longer
resolved (`attribute 'default' missing`). The build-before-commit gate
correctly refused to commit the broken lock. Fix: take opencode from
`llm-agents.packages.${system}.opencode` and thread it explicitly through
`callPackage` → `sandbox-spec.nix`, dropping the overlay entirely. Builds
against both old (1.17.10) and new (1.18.4) upstream. Bumped the lock to
1.18.4 in the same session.

Also restructured the workflow to match claude-code-nix-sandbox: a `gh api
repos/numtide/llm-agents.nix/commits/main` pre-check gates every step, so a
no-movement day skips the Nix install entirely (~5s no-op) instead of always
installing Nix + double-evaluating. Kept the opencode-*version* commit gate on
top (llm-agents.nix is a multi-tool monorepo; a rev bump need not touch
opencode). Verified: triggered run went green as a clean skip.

Aside: chased a suspected "re-link provider every session" bug — turned out to
be a false alarm (provider links do persist). opencode writes `auth.json`
in-place (no atomic rename) inside the bound `~/.local/share/opencode`, so the
directory bind already persists auth; the claude `~/.claude.json` fd-copy trick
addresses an atomic-rename race opencode doesn't have.
