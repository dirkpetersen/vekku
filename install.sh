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
    
    # Copy vekku script and replace placeholders
    sed "s|__VEKKU_ROOT__|${VEKKU_ROOT}|g; s|__WORK_DIR__|${WORK_DIR}|g" \
        "${VEKKU_ROOT}/vekku" > "$BIN_DIR/vekku"
    
    chmod +x "$BIN_DIR/vekku"
}

main() {
    # First check environment variables that are already set
    GITHUB_TOKEN="${GITHUB_TOKEN:-}"
    GITHUB_OWNER="${GITHUB_OWNER:-}"
    LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
    
    # Then try loading from .env files if any variables are still empty
    if [[ -z "$GITHUB_TOKEN" ]] || [[ -z "$GITHUB_OWNER" ]] || [[ -z "$LETSENCRYPT_EMAIL" ]]; then
        set -a
        if [[ -f .env ]]; then
            source .env
        else
            source .env.default || true
        fi
        set +a
    fi
    
    # Final validation of required variables
    if [[ -z "${GITHUB_TOKEN}" ]] || [[ -z "${GITHUB_OWNER}" ]] || [[ -z "${LETSENCRYPT_EMAIL}" ]]; then
        echo "Error: The following environment variables must be set (either in .env or exported):"
        [[ -z "${GITHUB_TOKEN}" ]] && echo "- GITHUB_TOKEN"
        [[ -z "${GITHUB_OWNER}" ]] && echo "- GITHUB_OWNER"
        [[ -z "${LETSENCRYPT_EMAIL}" ]] && echo "- LETSENCRYPT_EMAIL"
        exit 1
    fi
    
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
