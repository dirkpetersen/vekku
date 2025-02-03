#!/bin/bash
set -euo pipefail

VEKKU_ROOT="$(git rev-parse --show-toplevel)"
WORK_DIR="$VEKKU_ROOT/.work"
BIN_DIR="$HOME/.local/bin"

install_dependencies() {
    # Determine package manager
    if command -v apt &>/dev/null; then
        sudo apt install -y git certbot python3-venv jq
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y git certbot python3-virtualenv jq 
    else
        echo "Error: Could not find apt or dnf package manager. You need to install:"
        echo "- git"
        echo "- certbot"
        echo "- python3-venv"
        echo "- jq"
        echo "- libicu (for GitHub Actions runner)"
        exit 1
    fi

    # Install UV system-wide
    #curl -L https://astral.sh/uv/install.sh | sudo sh -s -- -y
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
    sudo tee /etc/systemd/system/vekku-traefik.service > /dev/null <<EOL
[Unit]
Description=Vekku Traefik Proxy
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

setup_monitor_service() {
    SERVICE_FILE="$HOME/.config/systemd/user/vekku-github-monitor.service"
    mkdir -p "$(dirname "$SERVICE_FILE")"
    
    tee "$SERVICE_FILE" > /dev/null <<EOL
[Unit]
Description=Vekku GitHub Monitor
After=network.target

[Service]
ExecStart=$VEKKU_ROOT/github-monitor.py
Restart=always
Environment="GITHUB_TOKEN=%h/vekku/.env"
WorkingDirectory=$VEKKU_ROOT

[Install]
WantedBy=default.target
EOL

    systemctl --user enable --now vekku-github-monitor.service
}

main() {
    # First check environment variables that are already set
    LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
    
    # Then try loading from .env files if LETSENCRYPT_EMAIL is still empty
    if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
        set -a
        if [[ -f .env ]]; then
            source .env
        else
            source .env.default || true
        fi
        set +a
    fi
    
    # Final validation of required variables
    if [[ -z "${LETSENCRYPT_EMAIL}" ]]; then
        echo "Error: LETSENCRYPT_EMAIL must be set (either in .env or exported)"
        exit 1
    fi
    
    install_dependencies
    traefik_install
    mkdir -p "$VEKKU_ROOT" "$WORK_DIR"
    setup_vekku_script
    setup_monitor_service
    
    # Enable and start Traefik
    sudo systemctl daemon-reload
    sudo systemctl enable --now vekku-traefik
    
    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo "Warning: ~/.local/bin is not in your PATH. Add it to use the vekku command."
    else
        echo "Installation complete. The vekku command is ready to use."
    fi
}

main "$@"
