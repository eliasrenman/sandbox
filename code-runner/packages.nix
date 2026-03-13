{ pkgs ? import <nixpkgs> { config = { allowUnfree = true; }; } }:

let
  packages = with pkgs; [
    # Version control
    git
    gh

    # Go toolchain
    go
    gopls
    gotools
    delve

    # Rust toolchain
    rustc
    cargo
    rustfmt
    clippy
    gcc # linker for Rust
    rust-analyzer

    # Node.js toolchain
    nodejs_22
    corepack_22
    claude-code
    nodePackages.typescript-language-server
    nodePackages.typescript

    # Python toolchain
    python3
    python3Packages.pip
    python3Packages.virtualenv
    python313Packages.jsonschema
    pyright

    # Editors
    neovim
    nano

    # Common CLI tools
    coreutils # cat, ls, cp, mv, etc.
    findutils
    gnugrep
    gnused
    gawk
    curl
    wget
    jq
    yq
    tree
    ripgrep
    fd
    bat
    htop
    unzip
    zip
    gnutar
    gzip
    openssh
    cacert
    less
    which
    gnumake
    pkg-config
  ];
in
pkgs.buildEnv {
  name = "code-runner-env";
  paths = packages;
  ignoreCollisions = true;
}
