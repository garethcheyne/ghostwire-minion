# Ghostwire Minion

A lightweight proxy agent that connects to a Ghostwire parent server and tunnels HTTP requests through this machine's IP address.

## Quick Install

On any Linux box:

```bash
curl -fsSL https://raw.githubusercontent.com/garethcheyne/ghostwire-minion/main/install.sh | sudo bash
```

Or clone and run manually:

```bash
git clone https://github.com/garethcheyne/ghostwire-minion.git
cd ghostwire-minion
sudo ./install.sh
```

## Setup

During installation you'll be asked two questions:

1. **Who is your parent?** — Your Ghostwire server URL (e.g. `https://ghostwire.err403.com`)
2. **API Key** — The minion API key from your Ghostwire dashboard (Worker Nodes page)

That's it. The minion registers itself, starts proxying, and reports back to the parent.

## How It Works

```
┌─────────────┐         ┌─────────────────┐         ┌──────────┐
│  Ghostwire  │──req──▶ │  Minion (proxy)  │──req──▶ │  Target  │
│   (parent)  │◀──res── │  IP: 203.0.1.5   │◀──res── │  Server  │
└─────────────┘         └─────────────────┘         └──────────┘
```

1. Ghostwire sends a request to the minion's `/proxy` endpoint
2. The minion makes the actual request from its own IP
3. The response is relayed back to Ghostwire
4. The minion sends periodic heartbeats to report its status

## Commands

```bash
# Check status
sudo systemctl status ghostwire-minion

# View logs
sudo journalctl -u ghostwire-minion -f

# Restart
sudo systemctl restart ghostwire-minion

# Health check
curl http://localhost:1080/health
```

## Uninstall

```bash
sudo systemctl stop ghostwire-minion
sudo systemctl disable ghostwire-minion
sudo rm /etc/systemd/system/ghostwire-minion.service
sudo rm -rf /opt/ghostwire-minion
```

## License

MIT
