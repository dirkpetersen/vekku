#!/bin/bash
set -euo pipefail

VEKKU_ROOT="$(git rev-parse --show-toplevel)"
WORK_DIR="$VEKKU_ROOT/.work"
BIN_DIR="$HOME/.local/bin"

install_dependencies() {
    # Determine package manager
    if command -v apt &>/dev/null; then
        sudo apt install -y git certbot python3-venv
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y git certbot python3-virtualenv
    else
        echo "Error: Could not find apt or dnf package manager. You need to install:"
        echo "- git"
        echo "- certbot"
        echo "- python3-venv"
        exit 1
    fi

    # Install UV system-wide
    #curl -L https://astral.sh/uv/install.sh | sudo sh -s -- -y
}

traefik_install() {
    # Create required directories
    sudo mkdir -p /etc/traefik/conf.d
    sudo chmod 755 /etc/traefik
    mkdir -p "${WORK_DIR}"
    
    # Set the GitHub repo URL
    REPO_URL="https://api.github.com/repos/traefik/traefik/releases/latest"

    # Fetch the latest release version (e.g., v3.1.4)
    LATEST_TRAEFIK_VERSION=$(curl -s $REPO_URL | grep "tag_name" | cut -d '"' -f 4)

    # Check if the current version matches the latest version
    if [[ -f "${WORK_DIR}/LATEST_TRAEFIK_VERSION" && "$(cat ${WORK_DIR}/LATEST_TRAEFIK_VERSION)" == "${LATEST_TRAEFIK_VERSION}" ]]; then
        echo "Traefik $LATEST_TRAEFIK_VERSION is already installed. Skipping download."
        return
    fi

    # Determine the architecture: amd64 or arm64
    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" ]]; then
        ARCH="arm64"
    elif [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi

    # Construct the download URL using the version number and architecture
    TAR_URL="https://github.com/traefik/traefik/releases/download/$LATEST_TRAEFIK_VERSION/traefik_${LATEST_TRAEFIK_VERSION}_linux_${ARCH}.tar.gz"

    # Download the tarball into the work directory
    echo "Downloading Traefik $LATEST_TRAEFIK_VERSION for $ARCH..."
    curl -L -o "${WORK_DIR}/traefik_${LATEST_TRAEFIK_VERSION}_linux_${ARCH}.tar.gz" $TAR_URL

    # Extract the tarball without changing directories
    echo "Extracting the tarball..."
    tar -xzf "${WORK_DIR}/traefik_${LATEST_TRAEFIK_VERSION}_linux_${ARCH}.tar.gz" -C "${WORK_DIR}"

    # Delete the tarball after extraction
    rm "${WORK_DIR}/traefik_${LATEST_TRAEFIK_VERSION}_linux_${ARCH}.tar.gz"
    #remove extra markdown files
    rm -f ${WORK_DIR}/LICENSE.md
    rm -f ${WORK_DIR}/CHANGELOG.md

    echo "${LATEST_TRAEFIK_VERSION}" > "${WORK_DIR}/LATEST_TRAEFIK_VERSION"

    echo "Traefik $LATEST_TRAEFIK_VERSION has been downloaded and extracted for $ARCH architecture."
    
    sudo mv "${WORK_DIR}/traefik" /usr/local/bin/traefik

    # Create systemd service for Traefik
    sudo tee /etc/systemd/system/traefik.service > /dev/null <<EOL
[Unit]
Description=Traefik Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.toml
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

    # Create base Traefik config
    sudo tee /etc/traefik/traefik.toml > /dev/null <<EOL
[entryPoints]
  [entryPoints.web]
    address = ":80"
  [entryPoints.web-secure]
    address = ":443"

[providers]
  [providers.file]
    directory = "/etc/traefik/conf.d"
    watch = true

[certificatesResolvers.letsencrypt.acme]
  email = "${LETSENCRYPT_EMAIL}"
  storage = "/etc/traefik/acme.json"
EOL

    # Add conditional DNS-01 challenge if using Route53
    if [[ "${LETSENCRYPT_MODE}" == "dns" ]]; then
    sudo tee -a /etc/traefik/traefik.toml > /dev/null <<EOL
  [certificatesResolvers.letsencrypt.acme.dnsChallenge]
    provider = "route53"
    delayBeforeCheck = 0
EOL
    else
    sudo tee -a /etc/traefik/traefik.toml > /dev/null <<EOL
  [certificatesResolvers.letsencrypt.acme.httpChallenge]
    entryPoint = "web"
EOL
    fi
}

setup_vekku_script() {
    mkdir -p "$BIN_DIR"
    # Store the VEKKU_ROOT in a config file
    mkdir -p "$HOME/.config/vekku"
    echo "$VEKKU_ROOT" > "$HOME/.config/vekku/root"
    
    tee "$BIN_DIR/vekku" > /dev/null <<'EOL'
#!/bin/bash
set -euo pipefail

# Determine VEKKU_ROOT from config or default
if [[ -f "$HOME/.config/vekku/root" ]]; then
    VEKKU_ROOT="$(cat "$HOME/.config/vekku/root")"
else
    VEKKU_ROOT="$HOME/vekku"
fi
WORK_DIR="${VEKKU_ROOT}/.work"

# Ensure required directories exist
mkdir -p "$VEKKU_ROOT" "$WORK_DIR"

# Source environment if available
if [[ -f "$VEKKU_ROOT/.env" ]]; then
    set -a
    source "$VEKKU_ROOT/.env"
    set +a
elif [[ -f "$VEKKU_ROOT/.env.default" ]]; then
    set -a
    source "$VEKKU_ROOT/.env.default"
    set +a
fi

# Parse arguments
GIT_URL="$1"
APP_FILE="${2:-app.py}"
APP_NAME="${3:-$(basename "$GIT_URL" .git)}"

# Clone repo
APP_DIR="$VEKKU_ROOT/$APP_NAME"
git clone "$GIT_URL" "$APP_DIR"

# Create virtual environment
UV_VENV="$APP_DIR/.venv"
uv venv "$UV_VENV"
source "$UV_VENV/bin/activate"
pip install -r "$APP_DIR/requirements.txt"
deactivate

# Create systemd service
tee "$APP_DIR/$APP_NAME.service" > /dev/null <<SERVICE_EOL
[Unit]
Description=$APP_NAME Service
After=network.target

[Service]
User=$(id -un)
WorkingDirectory=$APP_DIR
ExecStart=$UV_VENV/bin/python $APP_DIR/$APP_FILE
Restart=always

[Install]
WantedBy=default.target
SERVICE_EOL

# Install and enable service
systemctl --user enable --now "$APP_DIR/$APP_NAME.service"

# Create Traefik config
HOSTNAME="$APP_NAME.${BASE_DOMAIN}"
sudo tee "/etc/traefik/conf.d/$APP_NAME.toml" > /dev/null <<TRAEFIK_EOL
[http.routers.$APP_NAME]
  rule = "Host(\`$HOSTNAME\`)"
  service = "$APP_NAME"
  entryPoints = ["web-secure"]
  [http.routers.$APP_NAME.tls]
    certResolver = "letsencrypt"

[http.services.$APP_NAME.loadBalancer]
  [[http.services.$APP_NAME.loadBalancer.servers]]
    url = "http://localhost:$(systemctl --user show -p Listen "$APP_NAME.service" | cut -d= -f2)"
TRAEFIK_EOL

echo "Application $APP_NAME deployed to https://$HOSTNAME"
EOL

    chmod +x "$BIN_DIR/vekku"
}

main() {
    set -a
    if [[ -f .env ]]; then
        source .env
    else
        source .env.default || true
    fi
    set +a
    
    install_dependencies
    traefik_install
    mkdir -p "$VEKKU_ROOT" "$WORK_DIR"
    setup_vekku_script
    
    # Enable and start Traefik
    sudo systemctl daemon-reload
    sudo systemctl enable --now traefik
    
    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo "Warning: ~/.local/bin is not in your PATH. Add it to use the vekku command."
    else
        echo "Installation complete. The vekku command is ready to use."
    fi
}

main "$@"
