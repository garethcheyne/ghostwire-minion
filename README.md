# Ghostwire Minion

A lightweight proxy agent that connects to a Ghostwire parent server and tunnels HTTP requests through this machine's IP address.

## Quick Install

**Interactive** — you'll be prompted for parent URL and API key:

```bash
curl -fsSL https://raw.githubusercontent.com/garethcheyne/ghostwire-minion/main/install.sh | sudo bash
```

**Non-interactive** — pass everything on the command line (ideal for scripting/automation):

```bash
curl -fsSL https://raw.githubusercontent.com/garethcheyne/ghostwire-minion/main/install.sh \
  | sudo bash -s -- --parent https://ghostwire.err403.com --key gw-node-YOUR_KEY
```

Or clone and run manually:

```bash
git clone https://github.com/garethcheyne/ghostwire-minion.git
cd ghostwire-minion
sudo ./install.sh --parent https://ghostwire.err403.com --key gw-node-YOUR_KEY --port 1080
```

### Install options

| Flag | Description |
|------|-------------|
| `--parent`, `-p` | Ghostwire server URL |
| `--key`, `-k` | Minion API key (starts with `gw-node-`) |
| `--port` | Proxy listen port (default: `1080`) |

If `--parent` and `--key` are both provided, the installer runs fully non-interactive.

## Supported Distros

| Distro | Package Manager | Init System |
|--------|----------------|-------------|
| Alpine | apk | OpenRC |
| Debian / Ubuntu | apt | systemd |
| RHEL / Fedora / CentOS | dnf / yum | systemd |
| Arch | pacman | systemd |

The installer auto-detects your package manager and init system.

## Setup

During interactive installation you'll be asked two questions:

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

### systemd (Debian, Ubuntu, RHEL, Fedora, Arch)

```bash
sudo systemctl status ghostwire-minion
sudo journalctl -u ghostwire-minion -f
sudo systemctl restart ghostwire-minion
```

### OpenRC (Alpine)

```bash
sudo rc-service ghostwire-minion status
sudo tail -f /var/log/ghostwire-minion.log
sudo rc-service ghostwire-minion restart
```

### Health check (all distros)

```bash
curl http://localhost:1080/health
```

## Uninstall

### systemd

```bash
sudo systemctl stop ghostwire-minion
sudo systemctl disable ghostwire-minion
sudo rm /etc/systemd/system/ghostwire-minion.service
sudo systemctl daemon-reload
sudo rm -rf /opt/ghostwire-minion
```

### OpenRC (Alpine)

```bash
sudo rc-service ghostwire-minion stop
sudo rc-update del ghostwire-minion default
sudo rm /etc/init.d/ghostwire-minion
sudo rm -rf /opt/ghostwire-minion
```

## License

MIT
