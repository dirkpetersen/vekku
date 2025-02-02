#!/bin/bash
set -euo pipefail

VEKKU_ROOT="$HOME/vekku"
WORK_DIR="$VEKKU_ROOT/.work"
BIN_DIR="$HOME/.local/bin"

install_dependencies() {
    sudo apt-get update
    sudo apt-get install -y curl git systemd certbot python3-venv
    curl -L https://astral.sh/uv/install.sh | sudo sh -s -- -y
}

traefik_install() {
    sudo mkdir -p /etc/traefik/conf.d
    sudo chmod 755 /etc/traefik
    
    # Set the work directory
    WORK_DIR="~/vekku/.work"
    mkdir -p ${WORK_DIR}
    
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
    
    sudo mv traefik /usr/local/bin/traefik

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
  email = "admin@s.oregonstate.edu"
  storage = "/etc/traefik/acme.json"
  [certificatesResolvers.letsencrypt.acme.httpChallenge]
    entryPoint = "web"
EOL
}

setup_vekku_script() {
    mkdir -p "$BIN_DIR"
    tee "$BIN_DIR/vekku" > /dev/null <<'EOL'
#!/bin/bash
set -euo pipefail

VEKKU_ROOT="$HOME/vekku"
WORK_DIR="$VEKKU_ROOT/.work"

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
HOSTNAME="$APP_NAME.s.oregonstate.edu"
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
    install_dependencies
    traefik_install
    mkdir -p "$VEKKU_ROOT" "$WORK_DIR"
    setup_vekku_script
    
    # Enable and start Traefik
    sudo systemctl daemon-reload
    sudo systemctl enable --now traefik
    
    echo "Installation complete. Add ~/.local/bin to your PATH"
}

main "$@"
