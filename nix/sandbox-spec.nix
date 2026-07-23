# Single source of truth for what lives inside the sandbox:
#  - packages: tools placed on the in-sandbox PATH (includes opencode itself)
#  - hostEtcPaths: host /etc files bind-mounted read-only for DNS/TLS/user lookup
{ pkgs, opencode }:
{
  packages = with pkgs; [
    opencode
    nix
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
    # opencode reads images from the host clipboard by shelling out to a
    # clipboard binary: xclip (X11) or wl-paste (Wayland). Text copy uses OSC 52
    # and needs neither. Both are shipped since we forward both display sockets.
    xclip
    wl-clipboard
  ];

  hostEtcPaths = [
    "/etc/nix"
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
