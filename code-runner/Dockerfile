FROM nixos/nix:latest AS nix-builder

COPY code-runner/packages.nix /tmp/packages.nix

# Build the environment derivation and save the store path
# NIXPKGS_ALLOW_UNFREE needed for claude-code (unfree license)
RUN NIXPKGS_ALLOW_UNFREE=1 nix-build /tmp/packages.nix -o /tmp/code-runner-env \
    && readlink -f /tmp/code-runner-env > /tmp/env-store-path

# Final image
FROM nixos/nix:latest

# Fix: containerd >=2.2.0 (Go 1.24) rejects absolute symlinks in /etc.
# NixOS images symlink /etc/passwd and /etc/group into /nix/store which
# triggers "path escapes from parent". Resolve them to regular files.
RUN for f in /etc/passwd /etc/group; do \
      if [ -L "$f" ]; then cp --remove-destination "$(readlink -f "$f")" "$f"; fi; \
    done

# Copy the built Nix store
COPY --from=nix-builder /nix/store /nix/store
COPY --from=nix-builder /tmp/env-store-path /tmp/env-store-path

# Create a stable symlink from the store path
RUN mkdir -p /opt && ln -s "$(cat /tmp/env-store-path)" /opt/code-runner-env

COPY code-runner/packages.nix /etc/nix/packages.nix

# Set up environment — point PATH at the built env directly
ENV PATH="/opt/code-runner-env/bin:/usr/local/bin:/root/.nix-profile/bin:${PATH}" \
    SSL_CERT_FILE="/opt/code-runner-env/etc/ssl/certs/ca-bundle.crt" \
    NIX_SSL_CERT_FILE="/opt/code-runner-env/etc/ssl/certs/ca-bundle.crt" \
    LANG="en_US.UTF-8"

# Ensure common shebang paths work (NixOS only has /bin/sh by default)
RUN ln -sf /opt/code-runner-env/bin/env /usr/bin/env \
    && ln -sf "$(readlink -f /bin/sh)" /bin/bash

# Configure global gitignore to prevent committing internal factory files
RUN git config --global core.excludesFile /etc/gitignore_global
COPY code-runner/gitignore_global /etc/gitignore_global

# Set up a workspace directory
WORKDIR /workspace

# Default to bash
CMD ["bash"]
