# Sandbox

A containerized sandbox environment for running AI coding agents (Claude Code, etc.) in isolated Docker containers with persistent workspaces.

## Quick start

```bash
# Clone and alias (recommended)
alias sandbox="/path/to/sandbox.sh"

# Or copy it somewhere on your PATH
cp sandbox.sh ~/.local/bin/sandbox && chmod +x ~/.local/bin/sandbox
```

Make sure `ANTHROPIC_API_KEY` is exported in your shell — it's required for Claude Code inside the container.

```bash
sandbox up            # Start a new container (interactive)
sandbox enter <name>  # Open a shell in an existing container
sandbox list          # Show all managed containers
sandbox down <name>   # Stop and remove a container
sandbox help          # Full command reference
```

## Commands

| Command | Description |
|---------|-------------|
| `pull` | Pull the Docker image from the registry |
| `up [name]` | Start a new container (auto-generates a name if omitted) |
| `down <name\|id>` | Stop and remove a container |
| `enter <name\|id> [--role <role>]` | Open a shell (optionally with an agent role) |
| `exec <name\|id> [--role <role>] <cmd>` | Run a command non-interactively |
| `roles` | List available agent roles |
| `list [table\|json\|quiet]` | List containers |
| `status` | Overview of containers and image |
| `logs <name\|id> [--follow]` | View container logs |
| `restart <name\|id>` | Restart a container |
| `purge` | Remove all managed containers |

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SANDBOX_IMAGE` | `sandbox:latest` | Docker image to use |
| `SANDBOX_HOME` | `~/.config/sandbox` | Base config directory |
| `WORKSPACE_ROOT` | `$SANDBOX_HOME/workspaces` | Persistent workspace storage |
| `AGENTS_DIR` | `$SANDBOX_HOME/agents` | Directory containing agent role definitions |
| `ANTHROPIC_API_KEY` | _(required)_ | API key for Claude Code |
| `OPENAI_BASE_URL` | `http://host.docker.internal:$OPENAI_PORT` | Full URL for an OpenAI-compatible endpoint (e.g. `http://192.168.1.100:11434`) |
| `OPENAI_PORT` | `11434` | Port on host for the OpenAI-compatible endpoint (ignored when `OPENAI_BASE_URL` is set) |

## Agent roles

Place agent definitions in `$AGENTS_DIR/<role>/agent.md`. Each role directory can also contain an `instruction.md` and a `context/` folder with additional files that get injected into the container at `/workspace/.factory/`.

```bash
sandbox roles                              # List available roles
sandbox enter my-container --role planner  # Enter with a role
```

## Image

The `code-runner/` directory contains the Dockerfile and supporting files. The image is built on NixOS and includes Claude Code, Git, and common development tools defined in `code-runner/packages.nix`.

A new image is automatically built and published to the GitHub Container Registry on pushes to `main` that change files in `code-runner/`.
