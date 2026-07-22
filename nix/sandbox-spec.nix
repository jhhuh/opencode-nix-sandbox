# Single source of truth for what lives inside the sandbox:
#  - packages: tools placed on the in-sandbox PATH (includes opencode itself)
#  - hostEtcPaths: host /etc files bind-mounted read-only for DNS/TLS/user lookup
{ pkgs, opencode }:
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
