# check=skip=SecretsUsedInArgOrEnv
# (NSS_WRAPPER_PASSWD names a passwd file, not a secret.)

# Orca remote server: the Orca runtime (`orca-ide serve`) without a desktop window.
# Desktop, browser and mobile Orca clients pair with it over WebSocket.
#
# Upstream ships desktop packages only. This image installs the official .deb,
# which also pulls the Electron libraries and Xvfb. `orca-ide serve` starts its
# own Xvfb on :99.
#
# The coding-agent CLIs (claude, codex, …) are not baked in. The entrypoint
# installs the ones in ORCA_AGENTS into $HOME (the /home mount) on first start,
# where they persist across image updates and update themselves.

FROM node:22-bookworm-slim

ARG TARGETARCH

# Orca release. Update all three together with bin/bump-orca <version>.
ARG ORCA_VERSION=1.4.227
ARG ORCA_DEB_SHA256_AMD64=0891b7dde996a815660ea0c1d5b01979067501231ddbdc40bcbd223181b63112
ARG ORCA_DEB_SHA256_ARM64=6b3f08d070fe49b0f78eaa78c64dcf9781051e23b79d302bf4ea910877ba09a1

# Base tools. The toolbox is what agents expect in a dev box: git, ssh,
# compilers (node-pty and many npm packages build native code), python3.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      tini \
      tzdata \
      libnss-wrapper \
      fonts-liberation \
      fonts-dejavu-core \
      git \
      git-lfs \
      openssh-client \
      build-essential \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      fd-find \
      jq \
      less \
      procps \
      psmisc \
      unzip \
      zip \
      xz-utils \
      sqlite3 \
      tree \
      file \
      rsync \
      dnsutils \
      iputils-ping \
      netcat-openbsd \
      nano \
      vim-tiny \
      tmux \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd

# GitHub CLI (Orca shows PRs, issues and checks through gh) and the Docker CLI
# with the compose plugin (used only when you mount the Docker socket, see
# docker-compose.docker.yml). Both from their vendors' apt repositories.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli.gpg; \
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh docker-ce-cli docker-compose-plugin; \
    rm -rf /var/lib/apt/lists/*

# Orca. apt resolves the package's own dependencies (GTK, NSS, Xvfb, xdotool, …).
# The .deb does not declare every library Electron links (libgbm, libasound,
# …), so they are named here. The ldd check fails the build if one is missing.
RUN set -eux; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) deb_arch=amd64; sha="${ORCA_DEB_SHA256_AMD64}" ;; \
      arm64) deb_arch=arm64; sha="${ORCA_DEB_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    deb="/tmp/orca-ide_${ORCA_VERSION}_${deb_arch}.deb"; \
    curl -fsSL -o "${deb}" \
      "https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/orca-ide_${ORCA_VERSION}_${deb_arch}.deb"; \
    echo "${sha}  ${deb}" | sha256sum -c -; \
    apt-get update; \
    apt-get install -y --no-install-recommends "${deb}" \
      libgbm1 libasound2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
      libxrandr2 libxfixes3 libxext6 libcups2 libdbus-1-3 libnspr4 libnss3 \
      libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 libpango-1.0-0 libcairo2; \
    rm -rf /var/lib/apt/lists/* "${deb}"; \
    chmod 0755 /opt/Orca/chrome-sandbox; \
    if ldd /opt/Orca/orca-ide | grep 'not found'; then exit 1; fi

# User-defined extra apt packages, resolved at build time:
#   EXTRA_PACKAGES="golang htop" docker compose up -d --build
ARG EXTRA_PACKAGES=
RUN if [ -n "$EXTRA_PACKAGES" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends $EXTRA_PACKAGES \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# The credential store of Orca's Node server mixes in the machine ID. The
# entrypoint creates the ID once in $HOME, so it survives image updates.
RUN ln -sf /home/.config/orca-docker/machine-id /etc/machine-id \
    && mkdir -p /var/lib/dbus \
    && ln -sf /home/.config/orca-docker/machine-id /var/lib/dbus/machine-id

COPY entrypoint.sh healthcheck.sh install-agents orca-pairing orca-profile-backup /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
      /usr/local/bin/install-agents /usr/local/bin/orca-pairing /usr/local/bin/orca-profile-backup \
    && ln -s "$(ls /usr/lib/*/libnss_wrapper.so)" /usr/local/lib/libnss_wrapper.so \
    && install -d -m 0755 /var/lib/orca-docker \
    && cp /etc/passwd /var/lib/orca-docker/passwd \
    && cp /etc/group /var/lib/orca-docker/group \
    && chmod 0666 /var/lib/orca-docker/passwd /var/lib/orca-docker/group

# Chromium sandbox: the container has no user namespaces (Docker's seccomp
# profile) and no setuid (no-new-privileges), so no sandbox can start.
# `orca-ide serve` passes --no-sandbox to its main process only;
# ELECTRON_DISABLE_SANDBOX=1 covers every Electron process it starts.
# The container itself is the isolation boundary.
#
# Everything user-installed lands in $HOME so it survives image updates:
#  - `pip install --user` (PEP 668 guard off) → /home/.local
#  - `npm install -g`                         → /home/.npm-global
#  - agent CLIs from install-agents           → /home/.local/bin, /home/.npm-global/bin
#  - the `orca` CLI shim that `orca-ide serve` installs → /home/.local/bin
ENV HOME=/home \
    LANG=C.UTF-8 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    NPM_CONFIG_PREFIX=/home/.npm-global \
    PATH=/home/.local/bin:/home/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    ORCA_PORT=6768 \
    ORCA_SERVE_RUNTIME=electron \
    ELECTRON_DISABLE_SANDBOX=1 \
    ORCA_AGENTS="claude codex"
WORKDIR /home

# nss_wrapper gives the arbitrary PUID a passwd entry. The files start as
# copies of /etc/passwd and /etc/group, so lookups work before the entrypoint
# runs. The entrypoint rewrites them on every start (they are mode 0666: the
# PUID is not known at build time). This ENV comes after the last RUN on
# purpose: build steps use the real /etc/passwd.
ENV LD_PRELOAD=/usr/local/lib/libnss_wrapper.so \
    NSS_WRAPPER_PASSWD=/var/lib/orca-docker/passwd \
    NSS_WRAPPER_GROUP=/var/lib/orca-docker/group

LABEL org.opencontainers.image.title="orca-docker" \
      org.opencontainers.image.description="Orca remote server (orca-ide serve) for Docker and Synology NAS" \
      org.opencontainers.image.licenses="MIT" \
      io.github.stablyai.orca.version="${ORCA_VERSION}"

EXPOSE 6768
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 CMD ["healthcheck.sh"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
