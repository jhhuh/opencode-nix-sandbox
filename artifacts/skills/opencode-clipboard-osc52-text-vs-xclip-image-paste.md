# opencode clipboard: OSC 52 for text copy, xclip/wl-paste for image paste

## TL;DR

opencode's TUI does **not** use a clipboard binary for copying **text** — it
emits **OSC 52** terminal escapes, which travel through the terminal emulator
(and over SSH). A clipboard binary and an X/Wayland display are only needed for
the *other* direction: reading an **image** from the host clipboard to paste in.

Do not blindly copy claude-code-nix-sandbox's "add xclip so /copy works" fix —
the mechanisms differ.

## Evidence (from the opencode binary, v1.18.4)

```
grep -aoE 'osc52|OSC52|52;c|xclip|xsel|wl-copy|wl-paste|pbcopy' .opencode-wrapped
```
yields both families:
- `osc52`, `OSC52`, the raw `ESC ]52;c` byte sequence, and a renderer capability
  gate `osc52_support!=="unsupported"` → **text copy path**.
- `if(j==="linux"&&u("xclip"))return["xclip","-selection","clipboard",...]` next
  to an `image/png` handler → **image-read-from-clipboard path** (X11: xclip;
  Wayland: wl-paste).

## What this means for the sandbox

| direction | mechanism | needs clipboard binary? | needs display socket? |
|-----------|-----------|-------------------------|-----------------------|
| copy text out (opencode → host) | OSC 52 escape | no | no (rides the terminal) |
| paste image in (host → opencode) | xclip / wl-paste | **yes** | **yes** (X11 or Wayland) |

So text copy works with zero sandbox changes. Image paste needs, together:
1. `xclip` (X11) and/or `wl-clipboard` (Wayland) in `spec.packages`, **and**
2. display-socket forwarding in the bwrap backend:
   - X11: `--tmpfs /tmp/.X11-unix` + `--ro-bind-try /tmp/.X11-unix/X$n`,
     `--ro-bind $XAUTHORITY`, and `--setenv DISPLAY`/`XAUTHORITY`.
   - Wayland: `--ro-bind $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` + `--setenv
     WAYLAND_DISPLAY` (XDG_RUNTIME_DIR is already set inside the sandbox).

Place the socket binds in `exec bwrap` **after** `--tmpfs /tmp` and `--tmpfs
/run`, so the nested bind mountpoints land inside those tmpfses.

## Testing gotcha — xclip hangs a piped `--shell`

`printf x | xclip -selection clipboard` does **not** return: xclip forks a holder
process that keeps running to *serve* the CLIPBOARD selection until another app
takes ownership. Piped into `opencode-sandbox --shell`, the sandbox bash waits on
that child and never sees EOF → hangs until timeout.

Test **connectivity/readback** instead, which returns immediately:
```bash
echo 'xclip -selection clipboard -o' | ./result/bin/opencode-sandbox --shell
# prints the current host CLIPBOARD; "Can't open display" if forwarding is broken.
```
A full round-trip = write in one invocation (it will hang; that's the holder
doing its job), then read back the same string in a second invocation.

## Don't probe the host from inside the sandbox

Whether the *host* has xclip / which display protocol it runs are **host** facts.
`command -v xclip` or `echo $XDG_SESSION_TYPE` inside the sandbox measures the
sandbox, not the host. Get host facts from the user or from an observable
mechanism (the binary's own strings), never from a sandbox-local shell.
