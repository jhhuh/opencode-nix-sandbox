# opencode Bubblewrap Sandbox Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a pure-Nix flake that runs opencode inside an unprivileged bubblewrap sandbox with one writable project directory and persistent opencode auth/config.

**Architecture:** A `writeShellApplication` (`opencode-sandbox`) wraps `bwrap`, bind-mounting the project dir read-write, opencode's data/config dirs read-write, and git/ssh/gh/nix read-only. A `sandbox-spec.nix` centralises the in-sandbox package set and host `/etc` paths. The flake exposes `default` (wrapper + bundled opencode), `sandbox` (wrapper only), and `no-network` variants.

**Tech Stack:** Nix flakes, bubblewrap, `pkgs.opencode` (nixpkgs, v1.1.14), bash.

**Reference:** `github.com/jhhuh/claude-code-nix-sandbox` (the claude analogue). Design doc: `docs/plans/2026-06-25-opencode-bubblewrap-sandbox-design.md`.

**Notes for the executor:**
- This is a Nix project, not a unit-tested codebase. "Tests" are `nix flake check`, `nix build`, and runtime assertions inside `--shell` mode. Treat the expected command output as the pass/fail oracle.
- The three Nix files are mutually dependent; the flake will not evaluate until all three exist, so Task 1 creates them together and then verifies.
- Run all `nix` commands from the repo root. Flakes only see git-tracked files, so `git add` new files before `nix flake check` (or use `nix flake check` after staging).

---

### Task 1: Flake skeleton + sandbox spec + bubblewrap backend

**Files:**
- Create: `flake.nix`
- Create: `nix/sandbox-spec.nix`
- Create: `nix/backends/bubblewrap.nix`

**Step 1: Create `nix/sandbox-spec.nix`**

```nix
# Single source of truth for what lives inside the sandbox:
#  - packages: tools placed on the in-sandbox PATH (includes opencode itself)
#  - hostEtcPaths: host /etc files bind-mounted read-only for DNS/TLS/user lookup
{ pkgs }:
{
  packages = with pkgs; [
    opencode
    bashInteractive
    coreutils
    gitMinimal
    openssh
    gnused
    gnugrep
    gawk
    findutils
    which
    cacert
    gh
  ];

  hostEtcPaths = [
    "/etc/resolv.conf"
    "/etc/hosts"
    "/etc/nsswitch.conf"
    "/etc/passwd"
    "/etc/group"
    "/etc/ssl/certs"
    "/etc/static/ssl/certs"
    "/etc/localtime"
    "/etc/machine-id"
  ];
}
```

**Step 2: Create `nix/backends/bubblewrap.nix`**

```nix
# Bubblewrap sandbox backend for opencode.
#
# Usage: opencode-sandbox [--shell] [--gh-token] <project-dir> [opencode args...]
#
# Produces a writeShellApplication wrapping bwrap to isolate opencode with
# access to a single project directory. Persists opencode auth/config by
# bind-mounting ~/.local/share/opencode and ~/.config/opencode read-write.
{
  lib,
  pkgs,
  writeShellApplication,
  symlinkJoin,
  bubblewrap,
  cacert,
  coreutils,
  # Toggle host network access (set false to --unshare-net)
  network ? true,
  # Additional packages available inside the sandbox
  extraPackages ? [ ],
}:

let
  spec = import ../sandbox-spec.nix { inherit pkgs; };

  sandboxPath = symlinkJoin {
    name = "opencode-sandbox-path";
    paths = spec.packages ++ extraPackages;
  };

  caBundle = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  networkFlags = lib.optionalString (!network) "--unshare-net";
in
writeShellApplication {
  name = "opencode-sandbox";
  runtimeInputs = [ bubblewrap coreutils ];

  text = ''
    shell_mode=false
    gh_token=false
    while [[ "''${1:-}" == --* ]]; do
      case "''${1:-}" in
        --shell) shell_mode=true; shift ;;
        --gh-token) gh_token=true; shift ;;
        --help|-h) break ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done

    if [[ $# -lt 1 ]] || [[ "''${1:-}" == "--help" ]] || [[ "''${1:-}" == "-h" ]]; then
      echo "Usage: opencode-sandbox [--shell] [--gh-token] <project-dir> [opencode args...]" >&2
      echo "  --shell     Drop into bash instead of launching opencode" >&2
      echo "  --gh-token  Forward GH_TOKEN/GITHUB_TOKEN env vars into the sandbox" >&2
      exit 1
    fi

    project_dir="$(realpath "$1")"
    shift

    if [[ ! -d "$project_dir" ]]; then
      echo "Error: $project_dir is not a directory" >&2
      exit 1
    fi

    sandbox_home="$HOME"
    runtime_dir="/run/user/$(id -u)"

    # opencode auth + config persistence (read-write)
    data_args=()
    host_data_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
    host_config_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
    mkdir -p "$host_data_dir" "$host_config_dir"
    data_args+=(--bind "$host_data_dir" "$sandbox_home/.local/share/opencode")
    data_args+=(--bind "$host_config_dir" "$sandbox_home/.config/opencode")

    # Git and SSH forwarding (read-only)
    git_args=()
    if [[ -f "$HOME/.gitconfig" ]]; then
      git_args+=(--ro-bind "$HOME/.gitconfig" "$sandbox_home/.gitconfig")
    fi
    if [[ -d "$HOME/.config/git" ]]; then
      git_args+=(--dir "$sandbox_home/.config/git")
      git_args+=(--ro-bind "$HOME/.config/git" "$sandbox_home/.config/git")
    fi
    if [[ -d "$HOME/.ssh" ]]; then
      git_args+=(--ro-bind "$HOME/.ssh" "$sandbox_home/.ssh")
    fi
    if [[ -n "''${SSH_AUTH_SOCK:-}" ]] && [[ -e "''${SSH_AUTH_SOCK:-}" ]]; then
      git_args+=(--ro-bind "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK")
    fi

    # GitHub CLI config (read-only)
    gh_args=()
    if [[ -d "$HOME/.config/gh" ]]; then
      gh_args+=(--dir "$sandbox_home/.config/gh")
      gh_args+=(--ro-bind "$HOME/.config/gh" "$sandbox_home/.config/gh")
    fi

    # Curated provider-key env forwarding (+ user override list)
    env_args=()
    for var in \
      ANTHROPIC_API_KEY \
      OPENAI_API_KEY \
      OPENROUTER_API_KEY \
      GEMINI_API_KEY \
      GOOGLE_GENERATIVE_AI_API_KEY \
      GROQ_API_KEY \
      ''${OPENCODE_SANDBOX_FORWARD_ENV:-}; do
      if [[ -n "''${!var:-}" ]]; then
        env_args+=(--setenv "$var" "''${!var}")
      fi
    done

    if [[ "$gh_token" == true ]]; then
      for var in GH_TOKEN GITHUB_TOKEN; do
        if [[ -n "''${!var:-}" ]]; then
          env_args+=(--setenv "$var" "''${!var}")
        fi
      done
    fi

    if [[ -n "''${SSH_AUTH_SOCK:-}" ]]; then
      env_args+=(--setenv SSH_AUTH_SOCK "$SSH_AUTH_SOCK")
    fi
    if [[ -n "''${LANG:-}" ]]; then
      env_args+=(--setenv LANG "$LANG")
    fi
    if [[ -n "''${LC_ALL:-}" ]]; then
      env_args+=(--setenv LC_ALL "$LC_ALL")
    fi

    # Select entrypoint
    if [[ "$shell_mode" == true ]]; then
      entrypoint=(bash)
    else
      entrypoint=(opencode "$@")
    fi

    exec bwrap \
      --die-with-parent \
      --proc /proc \
      --dev /dev \
      --dev-bind /dev/shm /dev/shm \
      --ro-bind /nix/store /nix/store \
      --ro-bind-try /nix/var/nix/db /nix/var/nix/db \
      --bind-try /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket \
      --ro-bind-try /run/current-system/sw /run/current-system/sw \
      --tmpfs /tmp \
      --tmpfs /run \
      --dir "$runtime_dir" \
      --tmpfs /home \
      --dir "$sandbox_home" \
      --dir "$sandbox_home/.config" \
      --dir "$sandbox_home/.local" \
      --dir "$sandbox_home/.local/share" \
      "''${data_args[@]}" \
      "''${git_args[@]}" \
      "''${gh_args[@]}" \
      --bind "$project_dir" "$project_dir" \
      ${lib.concatMapStringsSep " \\\n  " (p: "--ro-bind-try ${p} ${p}") spec.hostEtcPaths} \
      --dir /bin \
      --symlink "${sandboxPath}/bin/bash" /bin/bash \
      --symlink "${sandboxPath}/bin/bash" /bin/sh \
      --dir /usr/bin \
      --symlink "${sandboxPath}/bin/bash" /usr/bin/bash \
      --ro-bind-try /usr/bin/env /usr/bin/env \
      "''${env_args[@]}" \
      --setenv HOME "$sandbox_home" \
      --setenv PATH "${sandboxPath}/bin" \
      --setenv TERM "''${TERM:-xterm-256color}" \
      --setenv NIX_REMOTE daemon \
      --setenv SSL_CERT_FILE "${caBundle}" \
      --setenv NIX_SSL_CERT_FILE "${caBundle}" \
      --setenv XDG_RUNTIME_DIR "$runtime_dir" \
      --setenv XDG_CONFIG_HOME "$sandbox_home/.config" \
      --setenv XDG_DATA_HOME "$sandbox_home/.local/share" \
      ${networkFlags} \
      --chdir "$project_dir" \
      "''${entrypoint[@]}"
  '';
}
```

**Step 3: Create `flake.nix`**

```nix
{
  description = "Sandboxed opencode sessions via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          # Bubblewrap wrapper + un-sandboxed opencode (both on PATH)
          default = pkgs.symlinkJoin {
            name = "opencode-sandbox";
            paths = [
              (pkgs.callPackage ./nix/backends/bubblewrap.nix { })
              pkgs.opencode
            ];
          };

          # Bubblewrap sandbox wrapper only
          sandbox = pkgs.callPackage ./nix/backends/bubblewrap.nix { };

          # Variant with network isolation
          no-network = pkgs.callPackage ./nix/backends/bubblewrap.nix {
            network = false;
          };
        });

      checks = forAllSystems (system: self.packages.${system});

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [ nixd nil nixpkgs-fmt ];
          };
        });
    };
}
```

**Step 4: Stage files and evaluate the flake**

Run:
```bash
git add flake.nix nix/sandbox-spec.nix nix/backends/bubblewrap.nix
nix flake check 2>&1 | tail -20
```
Expected: completes without error (downloads/builds the three packages). A generated `flake.lock` appears.

**Step 5: Build the wrapper and inspect it**

Run:
```bash
nix build .#sandbox --no-link --print-out-paths
```
Expected: prints a `/nix/store/...-opencode-sandbox` path, no errors.

**Step 6: Commit**

```bash
git add flake.nix flake.lock nix/sandbox-spec.nix nix/backends/bubblewrap.nix
git commit -m "Add bubblewrap backend, sandbox spec, and flake"
```

---

### Task 2: Verify filesystem isolation (shell mode)

**Files:** none (runtime verification).

**Step 1: Project dir is writable, HOME is ephemeral tmpfs**

Run:
```bash
mkdir -p /tmp/oc-test && echo hi > /tmp/oc-test/seed.txt
nix run .#sandbox -- --shell /tmp/oc-test -c '
  set -e
  echo "pwd=$(pwd)"
  touch ./written-inside.txt && echo "project write: OK"
  cat seed.txt
  echo content > "$HOME/ephemeral.txt" && echo "home write: OK"
  command -v opencode && echo "opencode on PATH: OK"
  ls -la /home
'
```
Expected: `pwd=/tmp/oc-test`; "project write: OK"; prints `hi`; "home write: OK"; an opencode store path; `/home` is an otherwise-empty tmpfs.

**Step 2: Confirm host home is NOT visible**

Run:
```bash
nix run .#sandbox -- --shell /tmp/oc-test -c '
  if [[ -e "$HOME/.bash_history" ]] || [[ -e "$HOME/Sync" ]]; then
    echo "LEAK: host home visible"; exit 1
  fi
  echo "host home isolated: OK"
'
```
Expected: "host home isolated: OK".

**Step 3: Confirm the project write landed on the host, the HOME write did not**

Run:
```bash
test -f /tmp/oc-test/written-inside.txt && echo "project persisted: OK"
ls /tmp/oc-test
```
Expected: "project persisted: OK"; `written-inside.txt` present (the `$HOME/ephemeral.txt` is gone — it lived in tmpfs).

**Step 4: Commit (if any tracked files changed)**

No source changes expected; skip commit if `git status` is clean.

---

### Task 3: Verify opencode config persistence, network toggle, and launch

**Files:** none (runtime verification).

**Step 1: opencode data/config dirs are bind-mounted RW**

Run:
```bash
nix run .#sandbox -- --shell /tmp/oc-test -c '
  set -e
  test -d "$HOME/.local/share/opencode" && echo "data dir mounted: OK"
  test -d "$HOME/.config/opencode" && echo "config dir mounted: OK"
  echo "{}" > "$HOME/.config/opencode/sandbox-probe.json" && echo "config write: OK"
'
test -f "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/sandbox-probe.json" \
  && echo "config persisted to host: OK"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/sandbox-probe.json"
```
Expected: all four "OK" lines — proving config written inside the sandbox lands in the host's `~/.config/opencode`.

**Step 2: Network reaches the host net by default**

Run:
```bash
nix run .#sandbox -- --shell /tmp/oc-test -c '
  getent hosts github.com >/dev/null 2>&1 && echo "dns: OK" || echo "dns: FAIL"
'
```
Expected: "dns: OK" (DNS resolves because `/etc/resolv.conf` is bound and the net namespace is shared).

**Step 3: `no-network` blocks egress**

Run:
```bash
nix run .#no-network -- --shell /tmp/oc-test -c '
  if getent hosts github.com >/dev/null 2>&1; then echo "net NOT isolated: FAIL"; else echo "net isolated: OK"; fi
'
```
Expected: "net isolated: OK".

**Step 4: Launch opencode (manual / interactive)**

Run:
```bash
nix run . -- /tmp/oc-test
```
Expected: the opencode TUI starts (requires a configured provider via env key or a prior `opencode auth login`). Quit with the opencode quit key. This step is a manual smoke test; note the result in the devlog.

---

### Task 4: README, artifacts, and final commit

**Files:**
- Create: `README.md`
- Create: `.envrc`
- Create: `artifacts/devlog.md`
- Create: `artifacts/plan_opencode-bubblewrap.md` (copy/symlink of this plan's intent, or a short pointer)

**Step 1: Create `.envrc`**

```bash
use flake
```

**Step 2: Write `README.md`** — quick-start mirroring the reference's tone:
- What it is (sandboxed opencode via Nix, bubblewrap backend).
- Install: `nix profile install <repo>` gives `opencode-sandbox` + `opencode`.
- Run: `nix run .#sandbox -- <project-dir>`, `--shell`, `--gh-token`, `nix run .#no-network`.
- What's sandboxed table (project RW, opencode data/config RW, git/ssh/gh RO, `/home` tmpfs, network shared/none).
- Requirements: Linux + user namespaces, Nix with flakes.

**Step 3: Write `artifacts/devlog.md`** — timestamped entry recording: milestone 1 scope, decisions (no Chromium, nixpkgs opencode, curated keys), verification results from Tasks 2–3, opencode version pinned.

**Step 4: Commit**

```bash
git add README.md .envrc artifacts/
git commit -m "Add README, direnv envrc, and devlog"
```

**Step 5: Push**

```bash
git push   # if a remote is configured; otherwise note for later
```

---

## Done criteria

- `nix flake check` passes.
- `nix run .#sandbox -- --shell <dir>` shows: project RW, `/home` tmpfs, host home isolated, opencode on PATH.
- opencode config written inside the sandbox persists to host `~/.config/opencode`.
- `no-network` blocks DNS/egress; default allows it.
- `nix run . -- <dir>` launches the opencode TUI.
- README + devlog committed.

## Deferred (future milestones)

systemd-nspawn backend, QEMU VM backend, Rust/Axum manager + htmx dashboard, `opencode-remote` SSH CLI, NixOS modules, nixosTest suite, mdBook docs.
