#!/bin/bash
set -euo pipefail

VEKKU_ROOT="$(git rev-parse --show-toplevel)"
WORK_DIR="$VEKKU_ROOT/.work"
BIN_DIR="$HOME/.local/bin"

install_dependencies() {
    # Determine package manager
    if command -v apt &>/dev/null; then
        sudo apt install -y git certbot python3-venv curl jq
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y git certbot python3-virtualenv curl jq
    else
        echo "Error: Could not find apt or dnf package manager. You need to install:"
        echo "- git"
        echo "- certbot"
        echo "- python3-venv"
        echo "- curl"
        echo "- jq"
        exit 1
    fi

    # Install UV system-wide
    #curl -L https://astral.sh/uv/install.sh | sudo sh -s -- -y
}

install_github_runner() {
    local runner_dir="${WORK_DIR}/actions-runner"
    mkdir -p "$runner_dir"
    cd "$runner_dir"

    # Get the latest runner version
    RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name[1:]')
    
    # Determine architecture
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        RUNNER_ARCH="x64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        RUNNER_ARCH="arm64"
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi

    # Download and extract runner
    curl -o "actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" -L \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
    tar xzf "./actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
    rm "actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

    # Get registration token
    RUNNER_TOKEN=$(curl -s -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/registration-token" | jq -r .token)

    # Configure and install runner
    ./config.sh --url "https://github.com/${GITHUB_OWNER}" \
                --token "${RUNNER_TOKEN}" \
                --name "$(hostname)-${RANDOM}" \
                --work "_work" \
                --labels "self-hosted,Linux,${RUNNER_ARCH}" \
                --unattended

    # Create systemd service for runner
    mkdir -p ~/.config/systemd/user/
    tee ~/.config/systemd/user/github-runner.service > /dev/null <<EOL
[Unit]
Description=GitHub Actions Runner
After=network.target

[Service]
Type=simple
ExecStart=${runner_dir}/run.sh
WorkingDirectory=${runner_dir}
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOL

    # Enable and start the service
    systemctl --user daemon-reload
    systemctl --user enable --now github-runner.service
    
    cd - > /dev/null
}

traefik_install() {
    # Check if traefik is already installed and running
    if systemctl is-active --quiet traefik; then
        echo "Traefik is already installed and running. Skipping installation."
        return
    fi

    # Create required directories
    sudo mkdir -p /etc/traefik/conf.d
    sudo chmod 755 /etc/traefik
    mkdir -p "${WORK_DIR}"
    
    # Set the GitHub repo URL
    REPO_URL="https://api.github.com/repos/traefik/traefik/releases/latest"

    # Fetch the latest release version (e.g., v3.1.4)
    LATEST_TRAEFIK_VERSION=$(curl -s $REPO_URL | grep "tag_name" | cut -d '"' -f 4)

    # Check if the current version matches the latest version
    if [[ -f "${WORK_DIR}/LATEST_TRAEFIK_VERSION" ]]; then
        CURRENT_VERSION=$(cat "${WORK_DIR}/LATEST_TRAEFIK_VERSION")
        if [[ "$CURRENT_VERSION" == "${LATEST_TRAEFIK_VERSION}" ]]; then
            echo "Traefik $LATEST_TRAEFIK_VERSION is already downloaded. Proceeding with configuration."
            sudo mv "${WORK_DIR}/traefik" /usr/local/bin/traefik 2>/dev/null || true
            configure_traefik
            return
        fi
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
    configure_traefik

}

configure_traefik() {
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

    # Create acme.json with correct permissions
    sudo touch /etc/traefik/acme.json
    sudo chmod 600 /etc/traefik/acme.json
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

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage: vekku <git-url> [app-file] [name]"
    echo "Example: vekku https://github.com/user/repo app.py myapp"
    exit 1
fi

# Parse arguments
GIT_URL="$1"
APP_FILE="${2:-app.py}"
APP_NAME="${3:-$(basename "$GIT_URL" .git)}"

# Validate GitHub URL and check if repo exists
if [[ ! "$GIT_URL" =~ ^https://github.com/[^/]+/[^/]+$ ]]; then
    echo "Error: Invalid GitHub URL format. Expected: https://github.com/user/repo"
    exit 1
fi

# Check if repository exists using GitHub API
REPO_PATH=$(echo "$GIT_URL" | cut -d'/' -f4-5)
if ! curl -s -o /dev/null -w "%{http_code}" "https://api.github.com/repos/$REPO_PATH" | grep -q "^200$"; then
    echo "Error: Repository $GIT_URL does not exist or is not accessible"
    exit 1
fi

# Clone repo into work directory
APP_DIR="$WORK_DIR/$APP_NAME"
git clone "$GIT_URL" "$APP_DIR" || {
    echo "Error: Failed to clone repository. Please check if it's private and you have access."
    exit 1
}

# Create virtual environment
UV_VENV="$APP_DIR/.venv"
# uv venv "$UV_VENV"
python3 -m venv "$UV_VENV"
source "$UV_VENV/bin/activate"

# Install requirements if they exist
if [[ -f "$APP_DIR/requirements.txt" ]]; then
    "$UV_VENV/bin/pip" install --upgrade pip"
    "$UV_VENV/bin/pip" install -r "$APP_DIR/requirements.txt"
fi
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
    
    # Validate required environment variables
    if [[ -z "${GITHUB_TOKEN:-}" ]] || [[ -z "${GITHUB_OWNER:-}" ]]; then
        echo "Error: GITHUB_TOKEN and GITHUB_OWNER must be set in .env"
        exit 1
    }
    
    install_dependencies
    traefik_install
    mkdir -p "$VEKKU_ROOT" "$WORK_DIR"
    setup_vekku_script
    install_github_runner
    
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
