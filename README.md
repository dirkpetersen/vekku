# Vekku
A docker-less Micro-PaaS inspired by Dokku using virtual environments or conda, Traefik and github runners.

If you have a standard application that can be installed via Conda or Python virtual environments, docker is a bit overkill. Most of the things you need to do can run under standard SystemD which comes with any Linux system. We use Treafik instead of NGINX as a reverse proxy and add a Github Runner to the mix and will get a Micro-PaaS with all the features we need in no time.

