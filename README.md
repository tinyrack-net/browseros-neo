# browseros-neo

[BrowserOS neo](https://github.com/browseros-ai/BrowserOS) packaged as a Docker image you can use from a web browser, in the style of [jlesage/docker-thunderbird](https://github.com/jlesage/docker-thunderbird).

- **Web GUI**: noVNC-based web UI served on port `5800` by [jlesage/baseimage-gui](https://github.com/jlesage/docker-baseimage-gui)
- **MCP**: exposes BrowserOS neo's MCP server on port `9300` behind Bearer-token authentication
- **Automatic builds**: a new `browserclaw/v*` release is detected and `ghcr.io/tinyrack-net/browseros-neo` is published automatically

## Quick start

```bash
export MCP_AUTH_TOKEN="$(openssl rand -hex 32)"
docker compose up -d
```

- GUI: <http://localhost:5800>
- MCP: `http://localhost:9300/mcp` (header `Authorization: Bearer $MCP_AUTH_TOKEN`)

Or with `docker run`:

```bash
docker run -d --name browseros-neo \
  --shm-size 2g \
  --security-opt seccomp=unconfined \
  -p 5800:5800 -p 9300:9300 \
  -e MCP_AUTH_TOKEN="$MCP_AUTH_TOKEN" \
  -v "$PWD/config:/config" \
  ghcr.io/tinyrack-net/browseros-neo:latest
```

## Image tags

| Tag | Meaning |
| --- | --- |
| `latest` | Latest stable BrowserOS neo release |
| `<version>` (e.g. `0.51.1.2`) | That BrowserOS neo version. Overwritten when the image repo itself changes |

Only `linux/amd64` is supported, because BrowserOS neo ships its Linux build for amd64 only.

## Environment variables

On top of the base image's [environment variables](https://github.com/jlesage/docker-baseimage-gui#environment-variables) (`USER_ID`, `GROUP_ID`, `TZ`, `WEB_AUTHENTICATION`, `SECURE_CONNECTION`, `DISPLAY_WIDTH`, `DISPLAY_HEIGHT`, and so on), the following are available.

| Variable | Description | Default |
| --- | --- | --- |
| `MCP_AUTH_TOKEN` | MCP Bearer token. If empty, the MCP endpoint is disabled. At least 16 characters from `A-Z a-z 0-9 . _ ~ + / = -` | (empty) |
| `MCP_LISTENING_PORT` | MCP proxy port inside the container | `9300` |
| `BROWSER_SANDBOX` | Chromium sandbox: `auto` (on when user namespaces are available, otherwise `--no-sandbox`), `on`, `off` | `auto` |
| `KEEP_APP_RUNNING` | Restart the browser automatically if it exits | `1` |

## Ports

| Port | Purpose |
| --- | --- |
| `5800` | Web GUI (HTTP, or HTTPS when `SECURE_CONNECTION=1`) |
| `9300` | MCP Streamable HTTP (`/mcp`), health check (`/healthz`) |
| `5900` | VNC (optional, provided by the base image) |

BrowserOS neo's internal ports (`9010` MCP, `9110` CDP, `9210` server) listen only on the container's loopback interface and are not exposed.

## Data

| Path | Contents |
| --- | --- |
| `/config/profile` | Browser profile (logins, cookies, extensions, BrowserOS neo settings and audit DB) |
| `/config/log` | Logs for nginx, the MCP proxy, and others |

Sessions and settings persist across container restarts and recreation, as long as `/config` is a volume.

## Web GUI window handling

BrowserOS neo draws its own window controls, including a minimize button. A minimized window is unmapped and stops rendering, and because the desktop has no taskbar and no window menu there would be no way to bring it back from the web browser, leaving the GUI on a black, unclickable screen. A `window-guard` service de-iconifies the application window as soon as it gets minimized.

## Connecting an MCP client

```json
{
  "mcpServers": {
    "browseros-neo": {
      "type": "http",
      "url": "http://<host>:9300/mcp",
      "headers": { "Authorization": "Bearer <MCP_AUTH_TOKEN>" }
    }
  }
}
```

### How the MCP proxy works

BrowserOS neo's MCP server (`127.0.0.1:9010/mcp`) has no authentication of its own, and to prevent DNS rebinding it accepts only requests whose `Host` is `127.0.0.1` or `localhost`. The image therefore runs a separate nginx instance that:

1. rejects any request without a matching `Authorization: Bearer <MCP_AUTH_TOKEN>` header with `401`,
2. rewrites `Host` to `127.0.0.1:9010` and strips the `Origin` and `Authorization` headers,
3. disables buffering so SSE streams pass through, then forwards to `127.0.0.1:9010`.

## Security notes

- Chromium's sandbox needs user namespaces, which Docker's default seccomp profile blocks. Run with `--security-opt seccomp=unconfined` (K8s: `securityContext.seccompProfile.type: Unconfined`) to enable the sandbox. Without it the browser falls back to `--no-sandbox` and shows a warning bar. With the fallback, renderer isolation is weak, so don't use it to browse untrusted sites.
  - `seccomp=unconfined` removes only the container's syscall filter. Namespaces, capability restrictions, and the non-root user stay in place, and Chromium applies its own seccomp-bpf filter to renderers.
- The web GUI has no authentication by default. Protect it with a reverse proxy or [web authentication](https://github.com/jlesage/docker-baseimage-gui#web-authentication) (`WEB_AUTHENTICATION=1` + `SECURE_CONNECTION=1`) before exposing it externally.
- The MCP token is passed in plaintext over HTTP. When it crosses a network, put it behind a TLS-terminating reverse proxy.

## Build

CI (`.github/workflows/build.yml`):

| Trigger | Behavior |
| --- | --- |
| Pull request | Build the latest release + smoke test (no push) |
| Push to `main` | Build the latest release, test, and push `<version>` and `latest` |
| Daily schedule (03:17 UTC) | If the latest release has no GHCR tag yet, build, test and push it |
| `workflow_dispatch` | Specify `browseros_version` to rebuild that version (in this case `latest` is not updated) |

Local build:

```bash
eval "$(./scripts/resolve-release.sh)"          # or ./scripts/resolve-release.sh 0.51.1.2
docker build \
  --build-arg BROWSEROS_VERSION="$version" \
  --build-arg BROWSEROS_SHA256="$sha256" \
  -t browseros-neo:test .
./tests/smoke.sh browseros-neo:test
```

`scripts/resolve-release.sh` uses the `digest` field of the GitHub release asset as the SHA256. If the digest is missing, it downloads the file and computes it.
