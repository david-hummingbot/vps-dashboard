# VPS Dashboard

A self-hosted server monitoring dashboard. All traffic stays inside your Tailscale network — no ports exposed to the internet.

```
┌─────────────────────────────────────────────────────┐
│   Browser (Tailscale)  →  Dashboard Server          │
│   Agent VPS-1          →  Dashboard Server (HTTP)   │
│   Agent VPS-2          →  Dashboard Server (HTTP)   │
└─────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Deploy the Dashboard Server

On your dashboard host:

```bash
cd server/

# Copy and edit the env file
cp .env.example .env
# Set API_KEY, optional Discord/Telegram webhook

docker compose up -d
```

The dashboard runs on port `8080`, bound to `127.0.0.1` only.
Access it via Tailscale:

```bash
# Option A: access via Tailscale IP directly (bind to TS IP)
# Edit docker-compose.yml: ports: "100.x.x.x:8080:8080"

# Option B: use Tailscale Serve (recommended)
tailscale serve 8080
# Then access https://<machine>.tail12345.ts.net
```

### 2. Install the Agent on Each VPS

No need to install Tailscale on the host — the agent ships with a Tailscale
sidecar container. Just provide an auth key.

```bash
# Clone or copy the agent/ directory, then:
cd agent/

# Copy and edit the env file
cp .env.example .env
# Set:
#   TS_AUTHKEY    = Tailscale auth key (https://login.tailscale.com/admin/settings/keys)
#   DASHBOARD_URL = http://<tailscale-ip-of-dashboard>:8080
#   API_KEY       = <same key as server>
#   NODE_NAME     = <friendly name for this server>

docker compose up -d
```

This starts two containers:
- `vps-agent-tailscale` — joins the machine to your tailnet using `TS_AUTHKEY`
- `vps-agent` — shares the sidecar's network (`network_mode: service:tailscale`)
  so it can reach the dashboard over Tailscale directly

The agent reports every 30 seconds (configurable via `REPORT_INTERVAL`).

> **Tip:** create a *reusable* + *ephemeral* auth key so re-deploys don't pile up
> stale nodes in your Tailscale admin console. Node state is persisted in
> `./tailscale-state` so restarts keep the same identity.

---

## Configuration

### Server `.env`

```env
# Required — set a strong secret
API_KEY=your-strong-secret-here

# Discord (optional)
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...

# Telegram (optional)
TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
TELEGRAM_CHAT_ID=-100123456789

# Alert thresholds (percent, default 90)
ALERT_CPU_THRESHOLD=90
ALERT_RAM_THRESHOLD=90
ALERT_DISK_THRESHOLD=90

# Seconds without check-in before node is marked offline (default 120)
OFFLINE_THRESHOLD_SECONDS=120
```

Create `server/.env.example` from the above and commit it (without real values).

### Agent Environment Variables

| Variable          | Required | Default        | Description                          |
|-------------------|----------|----------------|--------------------------------------|
| `TS_AUTHKEY`      | Yes      | —              | Tailscale auth key for the sidecar   |
| `DASHBOARD_URL`   | Yes      | —              | Tailscale URL of dashboard server    |
| `API_KEY`         | Yes      | `changeme`     | Must match server `API_KEY`          |
| `NODE_NAME`       | No       | `vps-agent`    | Dashboard label + Tailscale hostname |
| `REPORT_INTERVAL` | No       | `30`           | Seconds between metric reports       |

---

## Notifications

### Discord
Create a webhook in your Discord server (Channel Settings → Integrations → Webhooks).
Set `DISCORD_WEBHOOK_URL` on the server.

### Telegram
1. Create a bot via [@BotFather](https://t.me/BotFather) → copy the token
2. Add the bot to a group/channel and get the chat ID (use `@userinfobot`)
3. Set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` on the server

Alerts are sent for:
- Node going offline / coming back online
- Docker container status changes (running → stopped/exited)
- CPU / RAM / Disk exceeding threshold

---

## Security

- Dashboard is only accessible inside your Tailscale network (no internet exposure)
- All agent → server communication uses an `X-API-Key` header
- The Docker socket on agents is mounted read-only (`/var/run/docker.sock:ro`)
- Agents run with `pid: host` to read accurate host metrics (no sensitive data exposed)

---

## Project Structure

```
vps-dashboard/
├── server/
│   ├── main.py              # FastAPI application
│   ├── database.py          # SQLAlchemy models (SQLite)
│   ├── notifications.py     # Discord / Telegram webhooks
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── docker-compose.yml
│   └── static/
│       ├── index.html       # Dashboard UI
│       ├── app.js           # Auto-refreshing frontend
│       └── style.css        # Dark theme styles
└── agent/
    ├── agent.py             # Metric collector
    ├── requirements.txt
    ├── Dockerfile
    ├── .env.example         # TS_AUTHKEY, DASHBOARD_URL, API_KEY, ...
    └── docker-compose.yml   # agent + Tailscale sidecar
```
