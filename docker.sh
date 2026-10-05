#!/usr/bin/env bash
set -e

IMAGE_NAME="plinth-arch"
CONTAINER_NAME="plinth-dev"

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

# GITHUB_TOKEN comes from the host environment (your secret). Without it gh/git
# inside the container won't be authenticated, so warn loudly.
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "WARNING: GITHUB_TOKEN is not set on the host; gh/git will be unauthenticated." >&2
fi

# Build the image if it doesn't exist yet
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  docker build -t "$IMAGE_NAME" -f - . <<'EOF'
FROM archlinux:latest

# Base setup — nushell, eza, github-cli, and both JDKs are all in Arch's official repos
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm base-devel git gcc fish nushell eza sudo curl github-cli \
        jdk21-openjdk jdk25-openjdk && \
    pacman -Scc --noconfirm

# Default to Java 25 system-wide (archlinux-java ships with the jdk packages).
# Switch anytime with: sudo archlinux-java set java-21-openjdk
RUN archlinux-java set java-25-openjdk

# Create plinth user with passwordless sudo, default shell = fish
# (nushell stays installed — just run `nu` to use it)
RUN useradd -m -G wheel -s /usr/bin/fish plinth && \
    echo "plinth ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/plinth && \
    chmod 440 /etc/sudoers.d/plinth

USER plinth
WORKDIR /home/plinth

# Install rustup + stable as plinth
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/home/plinth/.local/bin:/home/plinth/.cargo/bin:${PATH}"

# Fish config: arrow prompt, JAVA_HOME, and ls -> eza with icons/colors.
# "fish_config prompt save" needs an interactive y/N confirm that hangs with
# no TTY at build time, so config.fish just loads the arrow prompt on startup.
#
# GitHub bootstrap (runs on each interactive shell start, only if GITHUB_TOKEN is set):
#   - gh already authenticates from the GITHUB_TOKEN env var
#   - git uses gh as its credential helper, so clones/pushes use the token
#   - git user.name/user.email are filled in from the GitHub API (noreply email),
#     only if you haven't set them already
RUN mkdir -p /home/plinth/.config/fish && \
    cat >> /home/plinth/.config/fish/config.fish <<'FISHEOF'
fish_config prompt choose arrow >/dev/null
set -gx JAVA_HOME /usr/lib/jvm/default
alias ls 'eza --color=always --icons=always --group-directories-first'

if status is-interactive; and set -q GITHUB_TOKEN
    git config --global credential.https://github.com.helper '!gh auth git-credential'

    if not git config --global user.email >/dev/null
        set -l info (gh api user --jq '[.id, .login, (.name // .login)] | @tsv' 2>/dev/null)
        if test -n "$info"
            set -l parts (string split \t -- $info)
            git config --global user.name "$parts[3]"
            git config --global user.email "$parts[1]+$parts[2]@users.noreply.github.com"
        else
            echo "plinth: couldn't fetch GitHub user (bad token?); git identity not set"
        end
    end

end
FISHEOF

# Nushell config (still installed, just not the default): alias ls -> eza with
# icons/colors, and a Ctrl+Backspace word-delete keybinding. Note: many
# terminals send the same byte (^H) for both plain Backspace and
# Ctrl+Backspace, so there's a second binding on char_h to catch that case too.
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

# From here on, make piped installs (curl | sh) fail the build if curl fails
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Clone oshi, build it, and install it system-wide (make install needs root)
RUN git clone https://github.com/plinthlol/oshi.git /home/plinth/oshi && \
    cd /home/plinth/oshi && \
    make && \
    sudo make install

# Grok Build
RUN curl -fsSL https://x.ai/cli/install.sh | bash

# dashe
RUN curl -fsSL https://plinthlol.github.io/dashe/install.sh | sh

# Create ~/dev and make it the default working dir
RUN mkdir -p /home/plinth/dev
WORKDIR /home/plinth/dev

CMD ["fish"]
EOF
fi

# If the container already exists, reattach to it so your files are still there.
# Otherwise create it for the first time.
# NOTE: env vars are fixed when the container is created. If you rotate the
# token, run with --reset so the new GITHUB_TOKEN gets picked up.
if docker container inspect "$CONTAINER_NAME" &>/dev/null; then
  echo "Resuming existing container '$CONTAINER_NAME' (use --reset for a fresh one)"
  docker start -ai "$CONTAINER_NAME"
else
  # `-e GITHUB_TOKEN` with no value forwards the host's value without putting
  # the token on the command line.
  docker run -it --name "$CONTAINER_NAME" \
    --hostname arch-plinth \
    -u plinth \
    -w /home/plinth/dev \
    -e GITHUB_TOKEN \
    "$IMAGE_NAME"
fi
