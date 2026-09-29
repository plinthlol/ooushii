#!/usr/bin/env bash
set -e

IMAGE_NAME="plinth-arch"
CONTAINER_NAME="plinth-dev"

# Build the image if it doesn't exist yet
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  docker build -t "$IMAGE_NAME" -f - . <<'EOF'
FROM archlinux:latest

# Base setup
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm base-devel git gcc fish sudo curl && \
    pacman -Scc --noconfirm

# Create plinth user with passwordless sudo
RUN useradd -m -G wheel -s /usr/bin/fish plinth && \
    echo "plinth ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/plinth && \
    chmod 440 /etc/sudoers.d/plinth

USER plinth
WORKDIR /home/plinth

# Install rustup + stable as plinth
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/home/plinth/.cargo/bin:${PATH}"

# Set fish prompt to arrow style. "fish_config prompt save" needs an
# interactive y/N confirmation that hangs/fails with no TTY at build time,
# so instead we just make config.fish load the arrow prompt on every startup.
RUN mkdir -p /home/plinth/.config/fish && \
    echo 'fish_config prompt choose arrow >/dev/null' >> /home/plinth/.config/fish/config.fish

# Create ~/dev and make it the default working dir
RUN mkdir -p /home/plinth/dev
WORKDIR /home/plinth/dev

CMD ["fish"]
EOF
fi

# Remove any existing container with the same name
docker rm -f "$CONTAINER_NAME" &>/dev/null || true

# Run it and drop straight into an interactive fish shell as plinth, inside ~/dev
docker run -it --name "$CONTAINER_NAME" \
  --hostname arch-plinth \
  -u plinth \
  -w /home/plinth/dev \
  "$IMAGE_NAME"

