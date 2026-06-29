# Arti proxy image

Custom Arti SOCKS/DNS proxy image with a Docker healthcheck that verifies an endpoint through Arti's SOCKS proxy.

## Build

```sh
docker build -t local/arti-socks-proxy:latest .
```

Or:

```sh
make build
```

## Run

```sh
docker run -d \
  --restart=always \
  --name arti-socks-proxy \
  --log-driver=local \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  -e HEALTHCHECK_URL='https://check.torproject.org/api/ip' \
  -e HEALTHCHECK_EXPECTED='"IsTor":true' \
  -e HEALTHCHECK_MAX_TIME=30 \
  -p 0.0.0.0:9150:9150/tcp \
  -p 0.0.0.0:5353:8853/udp \
  local/arti-socks-proxy:latest
```

Or:

```sh
make run
```

Or with Compose:

```sh
docker compose up -d --build
```

Or:

```sh
make compose-up
```

## Local test

Build the image, run a disposable Arti container, wait for bootstrap, and execute the healthcheck:

```sh
make test
```

To test a different endpoint:

```sh
make test HEALTHCHECK_URL='https://example.com' HEALTHCHECK_EXPECTED=''
```

## Publish to GitHub Container Registry

Assuming this project lives at `github.com/ntheile/arti-proxy`, publish the Docker image to GitHub Container Registry as:

```text
ghcr.io/ntheile/arti-proxy:latest
```

This repository includes `.github/workflows/publish-image.yml`:

```yaml
name: Publish Docker image

on:
  push:
    branches: [main, master]
    tags: ["v*"]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/ntheile/arti-proxy
          tags: |
            type=raw,value=latest,enable={{is_default_branch}}
            type=ref,event=tag
            type=sha

      - uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
```

Push to the default branch, or run the workflow manually from GitHub Actions. After it completes, the image should be available from GHCR.

The pinned Tor Arti base image used by this project is `linux/amd64`, so the published image is built as `linux/amd64`. Use a normal amd64 VM, which is the default for most DigitalOcean droplets.

## Run on a remote VM

On a fresh Ubuntu VM, install Docker if needed:

```sh
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Pull and run the image:

```sh
docker pull ghcr.io/ntheile/arti-proxy:latest

docker rm -f arti-socks-proxy >/dev/null 2>&1 || true

docker run -d \
  --restart=always \
  --name arti-socks-proxy \
  --log-driver=local \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  -e HEALTHCHECK_URL='https://check.torproject.org/api/ip' \
  -e HEALTHCHECK_EXPECTED='"IsTor":true' \
  -e HEALTHCHECK_MAX_TIME=30 \
  -p 0.0.0.0:9150:9150/tcp \
  -p 0.0.0.0:5353:8853/udp \
  ghcr.io/ntheile/arti-proxy:latest
```

If the GitHub package is private, log in to GHCR first with a GitHub personal access token that can read packages:

```sh
echo "$GITHUB_PAT" | docker login ghcr.io -u ntheile --password-stdin
docker pull ghcr.io/ntheile/arti-proxy:latest
```

If `docker pull` or `docker run` fails with `denied`, one of these is true:

- The GitHub Actions publish workflow has not run successfully yet.
- The image exists, but the GitHub package is private.
- The package is public in GitHub, but GHCR package visibility has not been changed to public.
- The image name or owner does not match `ghcr.io/ntheile/arti-proxy`.

For a public image, open the package in GitHub and set package visibility to public. For a private image, use the `docker login ghcr.io` command above before pulling.

Verify the container:

```sh
docker ps --filter name=arti-socks-proxy
docker inspect arti-socks-proxy --format '{{json .State.Health}}'
docker logs --tail=100 arti-socks-proxy
```

## Healthcheck settings

| Variable | Default | Description |
| --- | --- | --- |
| `HEALTHCHECK_URL` | `https://check.torproject.org/api/ip` | Endpoint to request through the SOCKS proxy. |
| `HEALTHCHECK_EXPECTED` | `"IsTor":true` | Text that must appear in the response. Set to an empty string to accept any HTTP 2xx response. |
| `HEALTHCHECK_MAX_TIME` | `30` | Curl timeout in seconds. |
| `SOCKS_HOST` | `127.0.0.1` | Hostname or IP for the local SOCKS listener inside the container. |
| `SOCKS_PORT` | `9150` | Port for the local SOCKS listener inside the container. |

## Verify

```sh
docker inspect arti-socks-proxy --format '{{json .State.Health}}'
docker exec arti-socks-proxy /usr/local/bin/arti-healthcheck.sh
```

Manual Tor check from the host:

```sh
curl --fail --silent --show-error --max-time 30 \
  --socks5-hostname 127.0.0.1:9150 \
  https://check.torproject.org/api/ip
```
