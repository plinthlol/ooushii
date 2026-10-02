#!/usr/bin/env bash
set -e

IMAGE_NAME="plinth-arch"
CONTAINER_NAME="plinth-dev"

# Build the image if it doesn't exist yet
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  docker build -t "$IMAGE_NAME" -f - . <<'EOF'
FROM archlinux:latest

# Base setup — nushell, eza, and both JDKs are all in Arch's official repos
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm base-devel git gcc fish nushell eza sudo curl \
        jdk21-openjdk jdk25-openjdk && \
    pacman -Scc --noconfirm

# Default to Java 25 system-wide (archlinux-java ships with the jdk packages).
# Switch anytime with: sudo archlinux-java set java-21-openjdk
RUN archlinux-java set java-25-openjdk

# Create plinth user with passwordless sudo, default shell = nushell
RUN useradd -m -G wheel -s /usr/bin/nu plinth && \
    echo "plinth ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/plinth && \
    chmod 440 /etc/sudoers.d/plinth

USER plinth
WORKDIR /home/plinth

# Install rustup + stable as plinth
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/home/plinth/.local/bin:/home/plinth/.cargo/bin:${PATH}"

# Fish stays installed and available, arrow prompt set for when it's used.
# "fish_config prompt save" needs an interactive y/N confirm that hangs with
# no TTY at build time, so config.fish just loads the arrow prompt on startup.
RUN mkdir -p /home/plinth/.config/fish && \
    echo 'fish_config prompt choose arrow >/dev/null' >> /home/plinth/.config/fish/config.fish

# Nushell config: alias ls -> eza with icons/colors, and a Ctrl+Backspace
# word-delete keybinding. Note: many terminals send the same byte (^H) for
# both plain Backspace and Ctrl+Backspace, so there's a second binding on
# char_h to catch that case too — whichever one your terminal actually sends
# will work.
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

CMD ["nu"]
EOF
fi

# Remove any existing container with the same name
docker rm -f "$CONTAINER_NAME" &>/dev/null || true

# Run it and drop straight into an interactive nushell shell as plinth, inside ~/dev
docker run -it --name "$CONTAINER_NAME" \
  --hostname arch-plinth \
  -u plinth \
  -w /home/plinth/dev \
  "$IMAGE_NAME"
