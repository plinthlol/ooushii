#!/usr/bin/env bash
set -e

IMAGE_NAME="plinth-arch"
CONTAINER_NAME="plinth-dev"
START_DIR="/home/plinth/oshi"   # where every shell starts

# Optional flags:
#   --reset    delete the container (you lose files inside it) and start fresh
#   --rebuild  delete the container AND the image, then rebuild everything
case "${1:-}" in
  --reset)
    docker rm -f "$CONTAINER_NAME" &>/dev/null || true
    ;;
  --rebuild)
    docker rm -f "$CONTAINER_NAME" &>/dev/null || true
    docker rmi -f "$IMAGE_NAME" &>/dev/null || true
    ;;
esac

# The secret is named GH_PAT on the host. gh/git inside the container read
# GITHUB_TOKEN, so GH_PAT wins and is copied into it.
if [ -n "${GH_PAT:-}" ]; then
  export GITHUB_TOKEN="$GH_PAT"
fi

# Actions secrets only exist inside the workflow run's own environment, never in
# a later ssh session. So fall back to a token file that the workflow writes.
if [ -z "${GITHUB_TOKEN:-}" ] && [ -r "$HOME/.gh_pat" ]; then
  GITHUB_TOKEN="$(tr -d '[:space:]' < "$HOME/.gh_pat")"
  export GITHUB_TOKEN
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "WARNING: no GH_PAT / GITHUB_TOKEN in this shell and no ~/.gh_pat file; gh/git will be unauthenticated." >&2
else
  echo "GitHub token found (${#GITHUB_TOKEN} chars), passing it into the shell."
fi

# Git identity inside the container.
export GIT_NAME="${GIT_NAME:-}"
export GIT_EMAIL="${GIT_EMAIL:-bbhattaraiprayogg@gmail.com}"

# Build the image if it doesn't exist yet
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  docker build -t "$IMAGE_NAME" - <<'EOF'
FROM archlinux:latest

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm base-devel git gcc fish nushell eza sudo curl github-cli \
        nodejs npm \
        jdk21-openjdk jdk25-openjdk && \
    pacman -Scc --noconfirm

RUN archlinux-java set java-25-openjdk

RUN useradd -m -G wheel -s /usr/bin/fish plinth && \
    echo "plinth ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/plinth && \
    chmod 440 /etc/sudoers.d/plinth

USER plinth
WORKDIR /home/plinth

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable

ENV NPM_CONFIG_PREFIX="/home/plinth/.local"
ENV PATH="/home/plinth/.local/bin:/home/plinth/.cargo/bin:${PATH}"

# AI coding agents from npm: Codex, pi, and opencode
RUN npm install -g @openai/codex @mariozechner/pi-coding-agent opencode-ai

RUN mkdir -p /home/plinth/.config/fish && \
    cat >> /home/plinth/.config/fish/config.fish <<'FISHEOF'
fish_config prompt choose arrow >/dev/null
set -gx JAVA_HOME /usr/lib/jvm/default
alias ls 'eza --color=always --icons=always --group-directories-first'

if status is-interactive
    test -n "$GIT_NAME"; and git config --global user.name "$GIT_NAME"
    test -n "$GIT_EMAIL"; and git config --global user.email "$GIT_EMAIL"

    if test -n "$GITHUB_TOKEN"
        gh auth setup-git --hostname github.com

        if not git config --global user.name >/dev/null; or not git config --global user.email >/dev/null
            set -l info (gh api user --jq '[.id, .login, (.name // .login)] | @tsv' 2>/dev/null)
            if test -n "$info"
                set -l parts (string split \t -- $info)
                git config --global user.name >/dev/null; or git config --global user.name "$parts[3]"
                git config --global user.email >/dev/null; or git config --global user.email "$parts[1]+$parts[2]@users.noreply.github.com"
            else
                echo "plinth: couldn't fetch GitHub user (bad token?); git identity not fully set"
            end
        end
    else
        echo "plinth: no GITHUB_TOKEN in this shell; gh/git are unauthenticated"
    end
end
FISHEOF

RUN mkdir -p /home/plinth/.config/nushell /home/plinth/.local/bin && \
    cat >> /home/plinth/.config/nushell/env.nu <<'NUENVEOF'

$env.PATH = ($env.PATH | prepend $"($env.HOME)/.local/bin")
$env.JAVA_HOME = "/usr/lib/jvm/default"
NUENVEOF

RUN cat >> /home/plinth/.config/nushell/config.nu <<'NUEOF'

alias ls = eza --color=always --icons=always --group-directories-first

$env.config.keybindings = ($env.config.keybindings | append [
  {
    name: delete_word_backward_backspace
    modifier: control
    keycode: backspace
    mode: [emacs, vi_normal, vi_insert]
    event: { edit: BackspaceWord }
  }
  {
    name: delete_word_backward_char_h
    modifier: control
    keycode: char_h
    mode: [emacs, vi_normal, vi_insert]
    event: { edit: BackspaceWord }
  }
])
NUEOF

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN git clone https://github.com/plinthlol/oshi.git /home/plinth/oshi && \
    cd /home/plinth/oshi && \
    make && \
    sudo make install

RUN curl -fsSL https://x.ai/cli/install.sh | bash

RUN curl -fsSL https://plinthlol.github.io/dashe/install.sh | sh

RUN mkdir -p /home/plinth/dev
WORKDIR /home/plinth/oshi

# Keep the container alive in the background; shells are attached with
# `docker exec` below, so each one gets the CURRENT env vars and start dir.
CMD ["sleep", "infinity"]
EOF
fi

# Create the container once (detached, no token baked into it)...
if ! docker container inspect "$CONTAINER_NAME" &>/dev/null; then
  docker run -d --name "$CONTAINER_NAME" \
    --hostname arch-plinth \
    -u plinth \
    "$IMAGE_NAME" >/dev/null
  echo "Created container '$CONTAINER_NAME'"
else
  echo "Resuming existing container '$CONTAINER_NAME' (use --reset for a fresh one)"
fi

# ...make sure it's running...
docker start "$CONTAINER_NAME" >/dev/null

# ...and open a shell in it. The token is forwarded per-shell (so rotating it
# never needs --reset) and the shell always starts in $START_DIR.
exec docker exec -it \
  -u plinth \
  -w "$START_DIR" \
  -e GITHUB_TOKEN \
  -e GIT_NAME \
  -e GIT_EMAIL \
  "$CONTAINER_NAME" fish
