# opencode-nix-sandbox

> **Warning:** Under active development and unstable. No guarantees of
> correctness, security, or fitness for any purpose. Run at your own risk.

Launch sandboxed [opencode](https://github.com/sst/opencode) sessions using Nix.

opencode is packaged via [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix) (daily auto-updated) and runs inside an unprivileged [bubblewrap](https://github.com/containers/bubblewrap)
sandbox with filesystem isolation: it can read and write a single project
directory, its own auth/config persist across runs, and git/ssh/gh credentials
are forwarded read-only so `git push` / `gh` keep working. This mirrors the
bubblewrap backend of [claude-code-nix-sandbox](https://github.com/jhhuh/claude-code-nix-sandbox);
opencode is a terminal TUI, so there is no bundled browser or display/GPU
forwarding.

## Quick Start

```bash
# Run opencode in a sandbox against a project directory
nix run github:jhhuh/opencode-nix-sandbox -- /path/to/project

# Drop into a shell inside the sandbox instead of launching opencode
nix run github:jhhuh/opencode-nix-sandbox#sandbox -- --shell /path/to/project

# Network-isolated sandbox
nix run github:jhhuh/opencode-nix-sandbox#no-network -- /path/to/project
```

Install both the sandbox wrapper and an un-sandboxed `opencode` (from `numtide/llm-agents.nix`) on your PATH:

```bash
nix profile install github:jhhuh/opencode-nix-sandbox
```

Authenticate either by running `opencode auth login` (the resulting
`~/.local/share/opencode/auth.json` is mounted into the sandbox) or by exporting
a provider API key before launching (see below).

## Usage

```
opencode-sandbox [--shell] [--gh-token] <project-dir> [opencode args...]
```

- `--shell` — drop into bash inside the sandbox instead of launching opencode.
  Note: this entrypoint is an interactive bash and does **not** forward trailing
  arguments; pipe commands via stdin to script it
  (`echo 'cmd' | opencode-sandbox --shell <dir>`).
- `--gh-token` — also forward `GH_TOKEN` / `GITHUB_TOKEN` into the sandbox.

### Provider API keys

These are forwarded into the sandbox when set on the host:
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`,
`GOOGLE_GENERATIVE_AI_API_KEY`, `GROQ_API_KEY`.

Forward additional variables by listing their names (space-separated) in
`OPENCODE_SANDBOX_FORWARD_ENV`:

```bash
OPENCODE_SANDBOX_FORWARD_ENV="MISTRAL_API_KEY DEEPSEEK_API_KEY" \
  nix run github:jhhuh/opencode-nix-sandbox -- /path/to/project
```

## What's Sandboxed

| Resource                              | Bubblewrap                         |
| ------------------------------------- | ---------------------------------- |
| Project directory                     | Read-write (bind-mount)            |
| `~/.local/share/opencode` (auth/data) | Read-write (bind-mount)            |
| `~/.config/opencode`                  | Read-write (bind-mount)            |
| `~/.gitconfig`, `~/.config/git`       | Read-only (bind-mount)             |
| `~/.ssh`, `SSH_AUTH_SOCK`             | Read-only (bind-mount)             |
| `~/.config/gh`                        | Read-only (bind-mount)             |
| `/nix/store`                          | Read-only                          |
| `/home`                               | Isolated (tmpfs)                   |
| Network                               | Shared by default / none with `no-network` |
| Nix commands                          | Via daemon (`NIX_REMOTE=daemon`)   |

Git/ssh/gh credentials are forwarded so the agent can push and use the GitHub
CLI. If you don't want that, run `#no-network` or remove those files from
`$HOME` before launching.

## Packages

| Package      | Description                                          | Requires        |
| ------------ | ---------------------------------------------------- | --------------- |
| `default`    | Bubblewrap sandbox + un-sandboxed opencode from [llm-agents.nix](https://github.com/numtide/llm-agents.nix) | User namespaces |
| `sandbox`    | Bubblewrap sandbox only                              | User namespaces |
| `no-network` | Bubblewrap sandbox with `--unshare-net`              | User namespaces |

## Caveats

- **`no-network` is best-effort.** It adds `--unshare-net`, but the nix daemon
  socket is still bound, so derivations that fetch (substituters,
  fixed-output) can still reach the network via the host daemon. Direct sockets
  from inside the sandbox are blocked.
- The kernel is shared with the host; bubblewrap provides namespace isolation,
  not a VM boundary.

## Requirements

- Nix with flakes enabled
- Linux with unprivileged user namespaces (for bubblewrap)
