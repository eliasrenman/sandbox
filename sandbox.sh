#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
SANDBOX_HOME="${SANDBOX_HOME:-${HOME}/.config/sandbox}"
IMAGE_NAME="${SANDBOX_IMAGE:-sandbox:latest}"
LABEL="sandbox.managed=true"
CONTAINER_PREFIX="sf"
OPENAI_PORT="${OPENAI_PORT:-11434}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-${SANDBOX_HOME}/workspaces}"
AGENTS_DIR="${AGENTS_DIR:-${SANDBOX_HOME}/agents}"

# Colors (disabled when not a tty)
if [[ -t 1 ]]; then
    BOLD=$'\033[1m' DIM=$'\033[2m' GREEN=$'\033[32m' RED=$'\033[31m'
    YELLOW=$'\033[33m' CYAN=$'\033[36m' RESET=$'\033[0m'
else
    BOLD='' DIM='' GREEN='' RED='' YELLOW='' CYAN='' RESET=''
fi

# ── Helpers ────────────────────────────────────────────────────────────────────
die()  { echo -e "${RED}error:${RESET} $*" >&2; exit 1; }
info() { echo -e "${CYAN}>>>${RESET} $*"; }
warn() { echo -e "${YELLOW}warning:${RESET} $*" >&2; }

# Generate a short unique name: sf-<adjective>-<noun>
generate_name() {
    local adjectives=(swift bright calm deep fast keen sharp warm bold clear)
    local nouns=(fox owl bear wolf hawk lynx pike rook wren crane)
    local adj="${adjectives[$((RANDOM % ${#adjectives[@]}))]}"
    local noun="${nouns[$((RANDOM % ${#nouns[@]}))]}"
    echo "${CONTAINER_PREFIX}-${adj}-${noun}"
}

# Resolve a user-provided identifier to a container ID.
# Accepts: full id, short id, or container name.
resolve_container() {
    local input="$1"
    # Try exact name match first (our managed containers)
    local id
    id=$(docker ps -a --filter "label=${LABEL}" --filter "name=^/${input}$" -q 2>/dev/null || true)
    if [[ -n "$id" ]]; then echo "$id"; return 0; fi

    # Try as container id prefix
    id=$(docker ps -a --filter "label=${LABEL}" -q | grep "^${input}" 2>/dev/null || true)
    if [[ -n "$id" ]]; then
        local count
        count=$(echo "$id" | wc -l | tr -d ' ')
        if [[ "$count" -gt 1 ]]; then
            die "Ambiguous identifier '${input}' matches ${count} containers. Be more specific."
        fi
        echo "$id"
        return 0
    fi

    die "No managed container found matching '${input}'.\nRun '${0##*/} list' to see running containers."
}

# Detect how to reach the host from inside containers
openai_base_url() {
    if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
        echo "${OPENAI_BASE_URL}"
    else
        echo "http://host.docker.internal:${OPENAI_PORT}"
    fi
}

# Network flags for host access
network_flags() {
    case "$(uname -s)" in
        Linux)
            # --network=host gives direct access to host services
            echo "--network=host"
            ;;
        *)
            # macOS/Windows: Docker Desktop routes host.docker.internal automatically
            echo "--add-host=host.docker.internal:host-gateway"
            ;;
    esac
}

# List available agent roles from docs/agents/
list_roles() {
    for d in "${AGENTS_DIR}"/*/; do
        [[ -f "${d}agent.md" ]] || continue
        basename "$d"
    done
}

# Interactive role picker — prints selected role name to stdout (menu goes to stderr)
select_role_interactive() {
    local roles=()
    while IFS= read -r r; do
        roles+=("$r")
    done < <(list_roles)

    if [[ ${#roles[@]} -eq 0 ]]; then
        warn "No agent roles found in ${AGENTS_DIR}"
        echo ""
        return
    fi

    echo -e "\n  ${BOLD}Available roles:${RESET}" >&2
    echo -e "  ${BOLD}0)${RESET} ${DIM}None${RESET}" >&2
    local i=1
    for r in "${roles[@]}"; do
        echo -e "  ${BOLD}${i})${RESET} ${r}" >&2
        ((i++))
    done
    echo "" >&2

    read -rp "Select role [0]: " choice
    choice="${choice:-0}"

    if [[ "$choice" == "0" ]]; then
        echo ""
        return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le ${#roles[@]} ]]; then
        echo "${roles[$((choice - 1))]}"
    else
        warn "Invalid selection, skipping role."
        echo ""
    fi
}

# Copy an agent role file into the container at /workspace/.factory/role.md
inject_role() {
    local container_id="$1"
    local role="$2"
    local role_file="${AGENTS_DIR}/${role}/agent.md"
    local instr_file="${AGENTS_DIR}/${role}/instruction.md"

    if [[ ! -f "$role_file" ]]; then
        local available
        available=$(list_roles | tr '\n' ', ' | sed 's/, $//')
        die "Unknown role '${role}'. Available: ${available}"
    fi

    docker exec "$container_id" mkdir -p /workspace/.factory
    docker cp "$role_file" "$container_id:/workspace/.factory/role.md"
    if [[ -f "$instr_file" ]]; then
        docker cp "$instr_file" "$container_id:/workspace/.factory/instruction.md"
    fi

    # Copy agent-specific context files into .factory/context/
    local context_dir="${AGENTS_DIR}/${role}/context"
    if [[ -d "$context_dir" ]]; then
        docker exec "$container_id" mkdir -p /workspace/.factory/context
        docker cp "$context_dir/." "$container_id:/workspace/.factory/context/"
    fi
    info "Injected role ${BOLD}${role}${RESET}"
}

# ── Commands ───────────────────────────────────────────────────────────────────

cmd_pull() {
    info "Pulling image ${BOLD}${IMAGE_NAME}${RESET}..."
    docker pull "${IMAGE_NAME}"
    info "Image ${BOLD}${IMAGE_NAME}${RESET} pulled successfully."
}

cmd_up() {
    local name="${1:-$(generate_name)}"
    local workspace_dir="${WORKSPACE_ROOT}/${name}"

    # Ensure image exists, pull from registry if missing
    if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
        warn "Image '${IMAGE_NAME}' not found. Pulling..."
        cmd_pull
    fi

    # Create persistent workspace
    mkdir -p "${workspace_dir}"

    local net_flags
    net_flags=$(network_flags)

    info "Starting container ${BOLD}${name}${RESET}..."
    local container_id
    # Pass ANTHROPIC_API_KEY if set (macOS Keychain is unavailable inside containers)
    local api_key_flags=()
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        api_key_flags+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
    else
        warn "ANTHROPIC_API_KEY is not set. Claude Code will not be authenticated inside the container."
        warn "Export ANTHROPIC_API_KEY in your shell or pass it when running this script."
    fi

    container_id=$(docker run -d \
        --name "${name}" \
        --label "${LABEL}" \
        --label "sandbox.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        ${net_flags} \
        -e "OPENAI_BASE_URL=$(openai_base_url)" \
        ${api_key_flags[@]+"${api_key_flags[@]}"} \
        -v "${workspace_dir}:/workspace" \
        -v "${HOME}/.claude:/home/user/.claude" \
        --restart unless-stopped \
        "${IMAGE_NAME}" \
        sleep infinity)

    echo -e "${GREEN}Container started${RESET}"
    echo -e "  name:      ${BOLD}${name}${RESET}"
    echo -e "  id:        ${DIM}${container_id:0:12}${RESET}"
    echo -e "  workspace: ${DIM}${workspace_dir}${RESET}"
    echo -e "  openai:    ${DIM}$(openai_base_url)${RESET}"
    echo ""

    # Machine-readable output on stdout when piped
    if [[ ! -t 1 ]]; then
        echo "CONTAINER_ID=${container_id}"
        echo "CONTAINER_NAME=${name}"
        return
    fi

    # Interactive: offer to copy current directory into container
    read -rp "Copy current directory into container workspace? [y/N] " copy_cwd
    if [[ "$copy_cwd" =~ ^[Yy]$ ]]; then
        info "Copying ${BOLD}$(pwd)${RESET} into container workspace..."
        docker cp "$(pwd)/." "$container_id:/workspace/"
        echo -e "${GREEN}Directory copied to /workspace${RESET}"
    fi

    echo ""

    # Interactive: offer to enter the container immediately
    read -rp "Enter container now? [y/N] " enter_now
    if [[ "$enter_now" =~ ^[Yy]$ ]]; then
        local role
        role=$(select_role_interactive)
        if [[ -n "$role" ]]; then
            cmd_enter "$name" --role "$role"
        else
            cmd_enter "$name"
        fi
    else
        echo -e "Enter with: ${BOLD}${0##*/} enter ${name}${RESET}"
    fi
}

cmd_down() {
    [[ $# -lt 1 ]] && die "Usage: ${0##*/} down <name|id>"
    local id
    id=$(resolve_container "$1")
    local name
    name=$(docker inspect --format '{{.Name}}' "$id" | sed 's|^/||')

    info "Stopping and removing ${BOLD}${name}${RESET} (${id:0:12})..."
    docker stop "$id" >/dev/null 2>&1 || true
    docker rm "$id" >/dev/null 2>&1

    echo -e "${GREEN}Container removed.${RESET}"
    echo -e "  Workspace preserved at: ${DIM}${WORKSPACE_ROOT}/${name}${RESET}"
    echo -e "  To delete workspace:    ${DIM}rm -rf ${WORKSPACE_ROOT}/${name}${RESET}"
}

cmd_enter() {
    [[ $# -lt 1 ]] && die "Usage: ${0##*/} enter <name|id> [--role <role>] [command...]"
    local target="$1"; shift
    local role=""

    # Parse --role from remaining args
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role)
                [[ -z "${2:-}" || "$2" == -* ]] && die "--role requires a role name. Available: $(list_roles | tr '\n' ', ' | sed 's/, $//')"
                role="$2"; shift 2 ;;
            *)
                args+=("$1"); shift ;;
        esac
    done

    local id
    id=$(resolve_container "$target")

    if [[ -n "$role" ]]; then
        inject_role "$id" "$role"
    fi

    # Default to bash, but allow custom commands
    if [[ ${#args[@]} -eq 0 ]]; then
        exec docker exec -it "$id" bash
    else
        exec docker exec -it "$id" "${args[@]}"
    fi
}

cmd_exec() {
    [[ $# -lt 2 ]] && die "Usage: ${0##*/} exec <name|id> [--role <role>] <command...>"
    local target="$1"; shift
    local role=""

    # Parse --role from remaining args
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role)
                [[ -z "${2:-}" || "$2" == -* ]] && die "--role requires a role name. Available: $(list_roles | tr '\n' ', ' | sed 's/, $//')"
                role="$2"; shift 2 ;;
            *)
                args+=("$1"); shift ;;
        esac
    done

    [[ ${#args[@]} -eq 0 ]] && die "Usage: ${0##*/} exec <name|id> [--role <role>] <command...>"

    local id
    id=$(resolve_container "$target")

    if [[ -n "$role" ]]; then
        inject_role "$id" "$role"
    fi

    # Non-interactive exec for automation
    docker exec "$id" "${args[@]}"
}

cmd_list() {
    local format="${1:-table}"

    case "$format" in
        json)
            docker ps -a --filter "label=${LABEL}" \
                --format '{"id":"{{.ID}}","name":"{{.Names}}","status":"{{.Status}}","state":"{{.State}}","created":"{{.CreatedAt}}","image":"{{.Image}}"}' \
                | jq -s '.'
            ;;
        quiet)
            docker ps -a --filter "label=${LABEL}" --format '{{.Names}}'
            ;;
        table|*)
            local count
            count=$(docker ps -a --filter "label=${LABEL}" -q | wc -l | tr -d ' ')
            echo -e "${BOLD}Software Factory Containers${RESET} (${count} total)\n"
            if [[ "$count" -eq 0 ]]; then
                echo -e "  ${DIM}No containers found. Run '${0##*/} up' to create one.${RESET}"
            else
                docker ps -a --filter "label=${LABEL}" \
                    --format "table {{.Names}}\t{{.State}}\t{{.Status}}\t{{.ID}}"
            fi
            echo ""
            ;;
    esac
}

cmd_status() {
    local running stopped total
    total=$(docker ps -a --filter "label=${LABEL}" -q | wc -l | tr -d ' ')
    running=$(docker ps --filter "label=${LABEL}" -q | wc -l | tr -d ' ')
    stopped=$((total - running))

    echo -e "${BOLD}Software Factory Status${RESET}"
    echo -e "  image:    ${IMAGE_NAME}"
    echo -e "  running:  ${GREEN}${running}${RESET}"
    echo -e "  stopped:  ${stopped}"
    echo -e "  total:    ${total}"
    echo -e "  openai:   $(openai_base_url)"
    echo ""

    # Image info
    if docker image inspect "${IMAGE_NAME}" &>/dev/null; then
        local image_size
        image_size=$(docker image inspect "${IMAGE_NAME}" --format '{{.Size}}' | awk '{printf "%.0fMB", $1/1024/1024}')
        echo -e "  image size: ${image_size}"
    else
        echo -e "  image: ${YELLOW}not built${RESET} (run '${0##*/} build')"
    fi

    if [[ "$total" -gt 0 ]]; then
        echo ""
        cmd_list table
    fi
}

cmd_logs() {
    [[ $# -lt 1 ]] && die "Usage: ${0##*/} logs <name|id> [--follow]"
    local target="$1"; shift
    local id
    id=$(resolve_container "$target")
    docker logs "$@" "$id"
}

cmd_restart() {
    [[ $# -lt 1 ]] && die "Usage: ${0##*/} restart <name|id>"
    local id
    id=$(resolve_container "$1")
    local name
    name=$(docker inspect --format '{{.Name}}' "$id" | sed 's|^/||')
    info "Restarting ${BOLD}${name}${RESET}..."
    docker restart "$id" >/dev/null
    echo -e "${GREEN}Restarted.${RESET}"
}

cmd_purge() {
    local ids
    ids=$(docker ps -a --filter "label=${LABEL}" -q)
    if [[ -z "$ids" ]]; then
        info "No managed containers to remove."
        return 0
    fi

    local count
    count=$(echo "$ids" | wc -l | tr -d ' ')

    # Ask for confirmation in interactive mode
    if [[ -t 0 ]]; then
        echo -e "${YELLOW}This will stop and remove ${BOLD}${count}${RESET}${YELLOW} container(s).${RESET}"
        read -rp "Continue? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; return 0; }
    fi

    info "Removing ${count} container(s)..."
    echo "$ids" | xargs docker stop >/dev/null 2>&1 || true
    echo "$ids" | xargs docker rm >/dev/null 2>&1
    echo -e "${GREEN}All managed containers removed.${RESET}"
    echo -e "  Workspaces preserved at: ${DIM}${WORKSPACE_ROOT}${RESET}"
}

cmd_help() {
    cat <<EOF
${BOLD}sandbox${RESET} — Manage Software Factory sandbox containers

${BOLD}USAGE${RESET}
    ${0##*/} <command> [arguments]

${BOLD}COMMANDS${RESET}
    ${BOLD}pull${RESET}                        Pull the Docker image from registry
    ${BOLD}up${RESET}    [name]                 Start a new container (interactive: copy cwd, auto-enter)
    ${BOLD}down${RESET}  <name|id>              Stop and remove a container
    ${BOLD}enter${RESET} <name|id> [--role <role>] [cmd...]
                                Open a shell (or run a command) in a container
    ${BOLD}exec${RESET}  <name|id> [--role <role>] <cmd...>
                                Run a command non-interactively (for automation)
    ${BOLD}roles${RESET}                        List available agent roles
    ${BOLD}list${RESET}  [table|json|quiet]      List containers (default: table)
    ${BOLD}status${RESET}                       Show overview of all containers and image
    ${BOLD}logs${RESET}  <name|id> [--follow]   View container logs
    ${BOLD}restart${RESET} <name|id>            Restart a container
    ${BOLD}purge${RESET}                        Remove ALL managed containers
    ${BOLD}help${RESET}                         Show this help

${BOLD}ENVIRONMENT${RESET}
    SANDBOX_HOME       Base config directory (default: ~/.config/sandbox)
    SANDBOX_IMAGE      Docker image to use (default: sandbox:latest)
    AGENTS_DIR         Directory for agent roles (default: \$SANDBOX_HOME/agents)
    WORKSPACE_ROOT     Directory for persistent workspaces (default: \$SANDBOX_HOME/workspaces)
    ANTHROPIC_API_KEY  API key for Claude Code (required — macOS Keychain is unavailable in containers)
    OPENAI_BASE_URL    Full URL for an OpenAI-compatible endpoint (overrides auto-detect)
    OPENAI_PORT        Port on host for the endpoint (default: 11434, ignored when OPENAI_BASE_URL is set)

${BOLD}EXAMPLES${RESET}
    ${0##*/} pull                           # Pull the image from registry
    ${0##*/} up                             # Start a container with auto-generated name
    ${0##*/} up my-project                  # Start a named container
    ${0##*/} enter my-project               # Open bash in the container
    ${0##*/} enter my-project --role code-monkey  # Enter with agent role injected
    ${0##*/} exec my-project --role planner ralph plan.md  # Run ralph with a role
    ${0##*/} roles                          # List available agent roles
    ${0##*/} list json                      # Machine-readable container list
    ${0##*/} down my-project                # Stop and remove the container
    ${0##*/} purge                          # Remove all containers

${BOLD}AI AGENT USAGE${RESET}
    # Agents can use non-interactive commands and JSON output:
    ${0##*/} list json                      # Get container list as JSON array
    ${0##*/} list quiet                     # Get just container names, one per line
    ${0##*/} up worker-1                    # Deterministic naming for orchestration
    ${0##*/} exec worker-1 ralph plan.md    # Run tasks non-interactively
    ${0##*/} down worker-1                  # Teardown by name
EOF
}

# ── Interactive Menu ───────────────────────────────────────────────────────────
cmd_interactive() {
    echo -e "${BOLD}Software Factory${RESET} — Interactive Mode\n"

    # Show current status summary
    local total running
    total=$(docker ps -a --filter "label=${LABEL}" -q 2>/dev/null | wc -l | tr -d ' ')
    running=$(docker ps --filter "label=${LABEL}" -q 2>/dev/null | wc -l | tr -d ' ')

    echo -e "  Containers: ${GREEN}${running} running${RESET} / ${total} total\n"

    # Menu options
    echo -e "  ${BOLD}1)${RESET} Pull image"
    echo -e "  ${BOLD}2)${RESET} Start a new container"
    echo -e "  ${BOLD}3)${RESET} Enter a container"
    echo -e "  ${BOLD}4)${RESET} Stop and remove a container"
    echo -e "  ${BOLD}5)${RESET} List containers"
    echo -e "  ${BOLD}6)${RESET} Show status"
    echo -e "  ${BOLD}7)${RESET} View container logs"
    echo -e "  ${BOLD}8)${RESET} Restart a container"
    echo -e "  ${BOLD}9)${RESET} Purge all containers"
    echo -e "  ${BOLD}h)${RESET} Help"
    echo -e "  ${BOLD}q)${RESET} Quit"
    echo ""

    read -rp "Choose an option: " choice
    echo ""

    case "$choice" in
        1) cmd_pull ;;
        2)
            read -rp "Container name (leave empty for auto): " name
            cmd_up ${name:+"$name"}
            ;;
        3)
            if [[ "$total" -eq 0 ]]; then
                warn "No containers available. Start one first."
                return 0
            fi
            cmd_list table
            read -rp "Container name or ID: " target
            [[ -z "$target" ]] && { warn "No container specified."; return 0; }
            local role
            role=$(select_role_interactive)
            if [[ -n "$role" ]]; then
                cmd_enter "$target" --role "$role"
            else
                cmd_enter "$target"
            fi
            ;;
        4)
            if [[ "$total" -eq 0 ]]; then
                warn "No containers to remove."
                return 0
            fi
            cmd_list table
            read -rp "Container name or ID to remove: " target
            [[ -z "$target" ]] && { warn "No container specified."; return 0; }
            cmd_down "$target"
            ;;
        5) cmd_list table ;;
        6) cmd_status ;;
        7)
            if [[ "$total" -eq 0 ]]; then
                warn "No containers available."
                return 0
            fi
            cmd_list table
            read -rp "Container name or ID: " target
            [[ -z "$target" ]] && { warn "No container specified."; return 0; }
            cmd_logs "$target"
            ;;
        8)
            if [[ "$total" -eq 0 ]]; then
                warn "No containers available."
                return 0
            fi
            cmd_list table
            read -rp "Container name or ID to restart: " target
            [[ -z "$target" ]] && { warn "No container specified."; return 0; }
            cmd_restart "$target"
            ;;
        9) cmd_purge ;;
        h) cmd_help ;;
        q) exit 0 ;;
        *) die "Invalid option '${choice}'." ;;
    esac
}

# ── Entrypoint ─────────────────────────────────────────────────────────────────
main() {
    # No arguments and interactive terminal → show interactive menu
    if [[ $# -eq 0 && -t 0 ]]; then
        cmd_interactive
        return
    fi

    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        pull)    cmd_pull "$@" ;;
        up)      cmd_up "$@" ;;
        down)    cmd_down "$@" ;;
        enter)   cmd_enter "$@" ;;
        exec)    cmd_exec "$@" ;;
        list|ls) cmd_list "$@" ;;
        status)  cmd_status "$@" ;;
        logs)    cmd_logs "$@" ;;
        restart) cmd_restart "$@" ;;
        purge)   cmd_purge "$@" ;;
        roles)   list_roles ;;
        help|-h|--help) cmd_help ;;
        *)       die "Unknown command '${cmd}'. Run '${0##*/} help' for usage." ;;
    esac
}

main "$@"
