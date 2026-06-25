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
