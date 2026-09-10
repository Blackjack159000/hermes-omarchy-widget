# Hermes Hub — Omarchy bar widget

A dashboard for [Hermes Agent](https://github.com/NousResearch/hermes-agent) that lives
in your Omarchy bar: 7-day token usage, spend, a per-agent breakdown, and a streaming
quick-chat panel that talks to every agent you have configured.

Built for the Quickshell-based Omarchy shell (Omarchy 4 / "Quattro").

```
┌──────────────────────────────────────────────┐
│  Hermes Hub                    3 agents   ↻  │
│  ──────────────────────────────────────────  │
│  Spend today   $0.42    Week   $3.10         │
│  ▁▂▅▇▅▂▁  (7-day token bars)                 │
│                                              │
│  Ops        ▸ 41K tok  $0.31   ● online        │
│  Research   ▸ 28K tok  $0.18   ● online        │
│  Coder      ▸  9K tok  $0.04   ● offline       │
│                                              │
│  [ Ask an agent… ]                           │
└──────────────────────────────────────────────┘
```

## Requirements

- Omarchy with the Quickshell shell, and the `omarchy` CLI.
- **Python 3** on the same machine (the bridge is standard library only — nothing to pip install).
- **At least one Hermes agent reachable** — see below. This is the only thing that needs thought.

## Install

**Option A — from git (recommended, gets you updates):**

```bash
omarchy plugin add https://github.com/<you>/hermes-hub --enable
```

**Option B — from a checkout (if I sent you the folder):**

```bash
cd hermes-hub
bash install.sh
```

Either way the installer restarts the shell and puts the widget in the **right** section of
the bar. If the icon doesn't appear: `omarchy restart shell`.

## What it needs from your machine

The widget is only a view. A small localhost service — `bridge.py`, started by the widget
itself — finds your agents and asks each one for its numbers. It looks in **two** places, in
this order:

**1. Omarchy's own agent integration** — `~/.config/hermes-omarchy/config.toml`.
If you set your agents up through Omarchy, every `[profiles.<Name>]` entry becomes a row in the
widget. This works for agents running on your laptop *and* for agents running on another
machine over your LAN/Tailscale — you just point `base_url` at them.

**2. Your own local Hermes install** — `~/.hermes/`.
If you have no Omarchy agent integration, the bridge falls back to this machine's Hermes.
Any profile with the **OpenAI-compatible API server** enabled becomes an agent:

```bash
# in ~/.hermes/.env, or ~/.hermes/profiles/<name>/.env
API_SERVER_ENABLED=true
API_SERVER_HOST=127.0.0.1
API_SERVER_PORT=8642          # give each profile its own port
API_SERVER_KEY=<any-secret>   # required whenever the API server is on
```

Restart Hermes afterwards, then reopen the panel.

**If neither is set up, the panel says so** — it prints what it looked for and how to fix it
rather than sitting there blank. You don't have to guess.

### Check it from the terminal first

Before blaming the widget, ask the bridge what it can see:

```bash
bash doctor.sh
```

```
Hermes Hub — agent discovery
  source : omarchy-agent-integration
  detail : 3 agent(s) from /home/you/.config/hermes-omarchy/config.toml
  agents : 3  (default: Ops)

    Ops              http://100.64.0.5:8642/v1            key=set      ok
    Research         http://100.64.0.5:8643/v1            key=set      ok
    Coder            http://100.64.0.5:8644/v1            key=set      OFFLINE
```

`source` tells you which route it took, and each agent gets a health check. Offline agents
still appear — the widget just shows them as offline until they answer.

## Using it

- **Click the icon** — the dashboard panel.
- **Click an agent row** — switches the quick-chat to that agent.
- **↻** — force a usage refresh (normally cached for 60s, 15s while anything is offline).
- **Right-click** — jump straight into a chat with the default agent.
- **Middle-click** — refresh.
- The chat panel streams replies as they arrive and keeps one session per agent, so your
  conversations persist between visits. **New chat** resets that agent's widget session.

### Settings

Per-widget settings live in Omarchy's normal widget settings UI:

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `120` | How often the panel refreshes in the background (min 30) |
| `hermesCommand` | `hermes-desktop` | Command used by the "open Hermes" button |

## How it works

```
Omarchy bar (Quickshell)
  └── Widget.qml ──── QML, spawns the bridge as a child process
        │
        └── HTTP on 127.0.0.1:8650
              └── bridge.py ── reads your agent config ── talks to each agent's
                                 Hermes API server (/api/sessions, /v1/health,
                                 /api/sessions/<id>/chat/stream)
```

The bridge **only ever listens on loopback**. It reads your own configuration and uses your
own keys; it sends nothing anywhere else, and there is no telemetry. It writes nothing except
the chat sessions you create. The widget and bridge live entirely inside
`~/.config/omarchy/plugins/io.github.giulio.hermes-hub/`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| No icon in the bar | `omarchy restart shell`, then `omarchy plugin list \| grep hermes-hub` |
| Enabled but never visible | It's probably in the **centre** section — Omarchy only reveals the centre while the pointer is on the bar. Move `{"id": "io.github.giulio.hermes-hub"}` into `bar.layout.right` in `~/.config/omarchy/shell.json`, then `omarchy restart shell` |
| Icon there, panel empty | `bash doctor.sh` — it will name the reason |
| Panel says "Bridge starting…" forever | Check `python3` exists; check port 8650 is free (`ss -tln \| grep 8650`) |
| An agent shows offline | That agent's Hermes isn't running/reachable — the widget is telling the truth |
| Everything shows $0.00 | The agent answered but has no sessions yet with usage recorded |
| Icon missing after an Omarchy update | `bash install.sh` again, or `omarchy plugin update` |

## Updating

- Installed via `omarchy plugin add` → `omarchy plugin update io.github.giulio.hermes-hub`
- Installed from a checkout → `git pull && bash install.sh`

## Uninstall

```bash
omarchy plugin remove io.github.giulio.hermes-hub
```

That removes the widget directory. Your Hermes setup is untouched — the widget only ever read it.

## Licence

MIT — see `LICENSE`.
