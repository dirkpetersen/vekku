
# Instructions for LLM 

I'd like to build a minimal PaaS to deploy apps such as flask and FastAPI.
I've been looking at Dokku but Dokku has a number of disadvantages: it requires docker which is resource intensive it also does not work on Amazon Linux 2023.

What I actually need is a system that will install flask or fastapi applications as --user systemd services and these applications should be installed with python virtual environments and not Docker containers. They should also be installed  triggered by gitHub actions, for example, if I, commit then an action should be triggered that will then automatically update the application and it goes live immediately. The reverse proxy should not be nginx but traefik which should listen on port 80 and 443.
It should  forward traffic to the back end flask or fast API daemon that listens on localhost. Traefik would be installed as root under System. We also need a way to host each application as a subdomain with "let's encrypt" certificates using certbot. The server is installed as s.sub.oregonstate.edu and I have an addional A record *.s.sub.oregonstate.edu so that all applictions such as myapp.s.ai.oregonstate.edu are routed to the right server without requiring addional dns config. Can you write a script that install everything on a linux server including the setup required for github (e.g. github runner). 

The script will install everything under the current non-root user account, including github runner, --user systemd services ,etc ,it will use the uv installer to create one enviromnet per application, we assume that the current user has sudo access and only the Traefik binary will be running as root (as systemd) service, Traefik will use letsencrypt,  https://doc.traefik.io/traefik/https/acme/ optionally with route53 (use the traefik_install() function below as a template.  Configurations will be in .env as a root of the git repository which will be by default in ~/vekku . All sites will be installed in ~/vekku/.work.  

Traefik will be setup with a static folder watch option https://github.com/dirkpetersen/forever-slurm/blob/main/traefik-static.toml where new applications can be installed. Please also draw inspirations from https://raw.githubusercontent.com/dirkpetersen/forever-slurm/refs/heads/main/config.sh and https://raw.githubusercontent.com/dirkpetersen/forever-slurm/refs/heads/main/forever-slurm.sh but you are no required to use this approach

there should be a bash script ~/local/bin/vekku that will have a structure 

vekku <git-url> [app] [name] for example "vekku https://github.com/dirkpetersen/moin app.py moinsen" after this is executed the git repos is checked out, the github runner is setup and a app.py is launched in a new virtual env created by uv and the app is reachable as moinsen.s.oregonstate.edu. If [app] is missing, we assume app.py and if [name] is missing we assume the github repository name 


traefik_install() {
  
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

}
