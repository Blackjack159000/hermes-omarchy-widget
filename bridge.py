#!/usr/bin/env python3
"""Hermes Hub bridge.

A tiny, dependency-free localhost service that powers the Omarchy "Hermes Hub"
bar widget. It reads the agents already configured for the Hermes desktop
client (``~/.config/hermes-omarchy/config.toml``) and talks to each agent's
Hermes gateway directly, so the widget never needs a bridge installed on the
remote host.

Endpoints (all on 127.0.0.1):

  GET  /health              -> {"ok": true}
  GET  /state               -> aggregated agents + usage/cost (cached)
  POST /refresh             -> force a usage refresh
  POST /chat                -> {"agent", "message"} -> {"run_id", "session_id"}
  GET  /chat/poll           -> ?run_id=... -> streamed text + completion
  POST /chat/stop           -> {"run_id"} -> abort a run
  POST /chat/reset          -> {"agent"}  -> delete the agent's widget session

The service only ever listens on the loopback interface.
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
import tomllib
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~")
# Primary source (yours if you use Omarchy's agent integration): a list of agents
# that may be local OR remote. Fallback source (works on a plain local install):
# this machine's own Hermes API servers — see discover_local_agents().
CONFIG_PATH = os.path.join(HOME, ".config", "hermes-omarchy", "config.toml")
HERMES_HOME = os.path.join(HOME, ".hermes")
HOST = "127.0.0.1"
PORT = int(os.environ.get("HERMES_HUB_PORT", "8650"))
CACHE_TTL = 60.0
# When any agent is unreachable (e.g. just after a reboot or resume, before
# Tailscale/the gateway is back) rebuild far more often so the widget heals
# quickly instead of showing stale "offline" data for a full minute.
DEGRADED_TTL = 15.0
HTTP_TIMEOUT = 12.0
STREAM_TIMEOUT = 900.0
MAX_SESSION_PAGES = 40

# Where the agents came from, and — when there are none — the sentence the widget
# shows instead of an unexplained empty dashboard. Filled in by load_agents().
_discovery = {"source": "unknown", "detail": "", "hint": ""}

_state_lock = threading.Lock()
_state = {"data": None, "ts": 0.0, "building": False}

_runs: dict[str, dict] = {}
_runs_lock = threading.Lock()

# Set by POST /shutdown. A freshly launched bridge that finds the port already
# taken asks the existing instance to step aside and retries, so an orphan left
# behind by a crashed shell can never permanently block the widget.
_shutdown = threading.Event()


# --------------------------------------------------------------------- config


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-") or "agent"


def _env_file(path: str) -> dict:
    """Parse KEY=VALUE lines from a Hermes .env. Missing file -> {}."""
    out: dict = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                out[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def _truthy(value) -> bool:
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def _local_endpoint(env: dict, label: str):
    """An agent entry from one profile's API-server settings, or None."""
    if not _truthy(env.get("API_SERVER_ENABLED")):
        return None
    host = (env.get("API_SERVER_HOST") or "127.0.0.1").strip()
    # A server bound to all interfaces still has to be REACHED on a real address.
    if host in ("0.0.0.0", "::", "*", ""):
        host = "127.0.0.1"
    port = env.get("API_SERVER_PORT") or "8642"
    return {
        "name": label,
        "model": label.lower(),
        "key": env.get("API_SERVER_KEY", ""),
        "base_url": f"http://{host}:{port}/v1",
    }


def discover_local_agents() -> list[dict]:
    """Agents served by THIS machine's Hermes install.

    A plain local install has no Omarchy agent integration to read, but every
    profile whose OpenAI-compatible API server is enabled is a perfectly good
    agent. That is the difference between "works on your machine" and "works on
    your friend's machine".
    """
    found: list[dict] = []
    entry = _local_endpoint(_env_file(os.path.join(HERMES_HOME, ".env")), "Hermes")
    if entry:
        found.append(entry)

    profiles_dir = os.path.join(HERMES_HOME, "profiles")
    try:
        names = sorted(os.listdir(profiles_dir))
    except OSError:
        names = []
    for name in names:
        env = _env_file(os.path.join(profiles_dir, name, ".env"))
        entry = _local_endpoint(env, name)
        if entry:
            found.append(entry)
    return found


def load_agents() -> tuple[list[dict], str]:
    """Agents in a stable order, from the best source this machine has.

    Source 1: the Omarchy agent-integration config (local or remote agents).
    Source 2: this machine's own Hermes API servers.
    Neither -> agents == [] and _discovery['hint'] explains what to do.
    """
    data: dict = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "rb") as fh:
                data = tomllib.load(fh)
        except (OSError, tomllib.TOMLDecodeError):
            data = {}

    server = data.get("server", {}) if isinstance(data.get("server"), dict) else {}
    auth = data.get("auth", {}) if isinstance(data.get("auth"), dict) else {}
    ui = data.get("ui", {}) if isinstance(data.get("ui"), dict) else {}
    top_base = str(server.get("base_url", "")).rstrip("/")
    top_model = str(server.get("model", ""))
    top_key = str(auth.get("key", ""))

    agents: list[dict] = []
    profiles = data.get("profiles", {})
    if isinstance(profiles, dict):
        for name, prof in profiles.items():
            if not isinstance(prof, dict):
                continue
            base = str(prof.get("base_url", "")).rstrip("/")
            if not base:
                continue
            agents.append(
                {
                    "name": str(name),
                    "model": str(prof.get("model", top_model)),
                    "key": str(prof.get("key", top_key)),
                    "base_url": base,
                }
            )

    if not agents and top_base:
        agents.append(
            {
                "name": "Hermes",
                "model": top_model or "hermes",
                "key": top_key,
                "base_url": top_base,
            }
        )

    if agents:
        _discovery.update(
            source="omarchy-agent-integration",
            detail=f"{len(agents)} agent(s) from {CONFIG_PATH}",
            hint="",
        )
    else:
        local = discover_local_agents()
        if local:
            agents = local
            _discovery.update(
                source="local-hermes-install",
                detail=f"{len(local)} API server(s) under {HERMES_HOME}",
                hint="",
            )
        else:
            _discovery.update(
                source="none",
                detail=(
                    f"no [profiles.*] in {CONFIG_PATH} and no API_SERVER_ENABLED "
                    f"profile under {HERMES_HOME}"
                ),
                hint=(
                    "No Hermes agents found. Enable the OpenAI-compatible API server "
                    "for at least one profile: add API_SERVER_ENABLED=true and "
                    "API_SERVER_KEY=<any-secret> to ~/.hermes/.env (or "
                    "~/.hermes/profiles/<name>/.env), restart Hermes, then reopen "
                    "this panel. Or configure Omarchy's agent integration."
                ),
            )

    for agent in agents:
        agent["root_url"] = (
            agent["base_url"][:-3]
            if agent["base_url"].endswith("/v1")
            else agent["base_url"]
        )
        agent["slug"] = _slug(agent["name"])

    default = str(ui.get("agent", "")) if isinstance(ui, dict) else ""
    if default and default not in [a["name"] for a in agents] and agents:
        default = ""
    return agents, default or (agents[0]["name"] if agents else "")


# ----------------------------------------------------------------------- http


def _headers(key: str) -> dict:
    headers = {"Accept": "application/json", "Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    return headers


def http_json(url: str, key: str, method: str = "GET", body=None, timeout=HTTP_TIMEOUT):
    payload = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=payload, headers=_headers(key), method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return json.loads(raw.decode("utf-8")) if raw else {}


# --------------------------------------------------------------------- usage


def _int(value) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _cost(session: dict) -> float:
    value = session.get("estimated_cost_usd")
    if value is None:
        value = session.get("actual_cost_usd")
    try:
        return float(value or 0.0)
    except (TypeError, ValueError):
        return 0.0


def _tokens(session: dict) -> int:
    return sum(
        _int(session.get(k))
        for k in (
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
        )
    )


def fetch_sessions(agent: dict) -> list[dict]:
    sessions: list[dict] = []
    offset = 0
    for _ in range(MAX_SESSION_PAGES):
        url = f"{agent['root_url']}/api/sessions?limit=200&offset={offset}"
        try:
            data = http_json(url, agent["key"])
        except Exception:
            break
        rows = data.get("data") or []
        sessions.extend(rows)
        if not data.get("has_more") or not rows:
            break
        offset += len(rows)
    return sessions


def agent_health(agent: dict) -> dict:
    for path in ("/v1/health", "/health"):
        try:
            data = http_json(f"{agent['root_url']}{path}", agent["key"], timeout=6.0)
            if isinstance(data, dict) and data.get("status") == "ok":
                return {
                    "ok": True,
                    "status": str(data.get("status", "ok")),
                    "version": str(data.get("version", "")),
                }
        except Exception:
            continue
    return {"ok": False, "status": "offline", "version": ""}


def _day_key(ts) -> str:
    try:
        return datetime.fromtimestamp(float(ts)).strftime("%Y-%m-%d")
    except (TypeError, ValueError, OSError):
        return ""


def build_state() -> dict:
    agents, default_agent = load_agents()

    def collect(agent: dict) -> tuple[dict, list[dict], dict]:
        return agent, fetch_sessions(agent), agent_health(agent)

    results = []
    if agents:
        with ThreadPoolExecutor(max_workers=min(8, len(agents))) as pool:
            results = list(pool.map(collect, agents))

    today = datetime.now().date()
    days = [(today - timedelta(days=offset)) for offset in range(6, -1, -1)]
    day_keys = [d.strftime("%Y-%m-%d") for d in days]
    by_day = {
        key: {"date": key, "label": datetime.strptime(key, "%Y-%m-%d").strftime("%a"),
              "tokens": 0, "cost": 0.0, "sessions": 0}
        for key in day_keys
    }

    all_time = {"tokens": 0, "cost": 0.0, "sessions": 0}
    week = {"tokens": 0, "cost": 0.0, "sessions": 0}
    today_stats = {"tokens": 0, "cost": 0.0, "sessions": 0}
    agent_rows = []

    for agent, sessions, health in results:
        row = {
            "name": agent["name"],
            "model": agent["model"],
            "slug": agent["slug"],
            "health": health,
            "tokens": 0,
            "cost": 0.0,
            "sessions": 0,
            "weekTokens": 0,
            "weekCost": 0.0,
        }
        for session in sessions:
            tokens = _tokens(session)
            cost = _cost(session)
            all_time["tokens"] += tokens
            all_time["cost"] += cost
            all_time["sessions"] += 1
            row["tokens"] += tokens
            row["cost"] += cost
            row["sessions"] += 1

            key = _day_key(session.get("started_at") or session.get("last_active"))
            if key in by_day:
                by_day[key]["tokens"] += tokens
                by_day[key]["cost"] += cost
                by_day[key]["sessions"] += 1
                week["tokens"] += tokens
                week["cost"] += cost
                week["sessions"] += 1
                row["weekTokens"] += tokens
                row["weekCost"] += cost
                if key == day_keys[-1]:
                    today_stats["tokens"] += tokens
                    today_stats["cost"] += cost
                    today_stats["sessions"] += 1
        agent_rows.append(row)

    agent_rows.sort(key=lambda r: r["weekCost"], reverse=True)

    return {
        "ok": True,
        "updated": time.time(),
        "defaultAgent": default_agent,
        "discovery": dict(_discovery),
        "agents": [
            {
                "name": row["name"],
                "model": row["model"],
                "slug": row["slug"],
                "health": row["health"],
            }
            for row in agent_rows
        ],
        "usage": {
            "allTime": all_time,
            "week": week,
            "today": today_stats,
            "byDay": [by_day[key] for key in day_keys],
            "byAgent": agent_rows,
        },
    }


def _refresh_worker() -> None:
    try:
        data = build_state()
        with _state_lock:
            _state["data"] = data
            _state["ts"] = time.time()
    finally:
        with _state_lock:
            _state["building"] = False


def _degraded(data: dict) -> bool:
    agents = data.get("agents") or []
    return any(not (a.get("health") or {}).get("ok") for a in agents)


def ensure_refresh(force: bool = False) -> bool:
    with _state_lock:
        data = _state["data"]
        ttl = DEGRADED_TTL if (data is not None and _degraded(data)) else CACHE_TTL
        fresh = data is not None and (time.time() - _state["ts"]) < ttl
        if not force and fresh:
            return False
        if _state["building"]:
            return False
        _state["building"] = True
    threading.Thread(target=_refresh_worker, daemon=True).start()
    return True


def current_state() -> dict:
    with _state_lock:
        data = _state["data"]
        building = _state["building"]
    if data is None:
        return {"ok": False, "loading": True, "agents": [], "usage": None}
    result = dict(data)
    result["stale"] = building
    return result


# ---------------------------------------------------------------------- chat


def _session_id(agent: dict) -> str:
    return f"omarchy-hub-{agent['slug']}"


def ensure_session(agent: dict) -> None:
    body = {"id": _session_id(agent), "source": "api_server"}
    try:
        http_json(f"{agent['root_url']}/api/sessions", agent["key"], "POST", body)
    except urllib.error.HTTPError as exc:
        if exc.code not in (409,):
            pass
    except Exception:
        pass


def _stream_run(run_id: str, agent: dict, message: str) -> None:
    run = _runs.get(run_id)
    if run is None:
        return
    url = f"{agent['root_url']}/api/sessions/{_session_id(agent)}/chat/stream"
    body = json.dumps({"message": message, "model": agent["model"]}).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=_headers(agent["key"]), method="POST")
    try:
        with urllib.request.urlopen(req, timeout=STREAM_TIMEOUT) as resp:
            event = None
            for raw in resp:
                if run["abort"].is_set():
                    break
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if line.startswith("event:"):
                    event = line[len("event:"):].strip()
                    continue
                if line.startswith("data:"):
                    chunk = line[len("data:"):].strip()
                    try:
                        payload = json.loads(chunk)
                    except json.JSONDecodeError:
                        event = None
                        continue
                    if event == "assistant.delta":
                        run["text"] += str(payload.get("delta", ""))
                    elif event == "assistant.completed":
                        run["text"] = str(payload.get("content", run["text"]))
                    elif event == "run.completed":
                        run["usage"] = payload.get("usage")
                        if payload.get("session_id"):
                            run["session_id"] = str(payload["session_id"])
                    elif event == "error":
                        run["error"] = str(payload.get("message", "Agent error"))
                    event = None
                    continue
                if line == "":
                    event = None
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read().decode("utf-8", "replace")[:300]
        except Exception:
            detail = str(exc)
        run["error"] = f"HTTP {exc.code}: {detail}"
    except Exception as exc:
        run["error"] = str(exc)
    finally:
        run["done"] = True


def start_chat(agent_name: str, message: str) -> dict:
    agents, default_agent = load_agents()
    if not agents:
        raise ValueError("No Hermes agents configured")
    agent = next((a for a in agents if a["name"] == agent_name), None)
    if agent is None:
        agent = next((a for a in agents if a["name"] == default_agent), agents[0])
    ensure_session(agent)
    run_id = uuid.uuid4().hex
    with _runs_lock:
        _runs[run_id] = {
            "agent": agent["name"],
            "session_id": _session_id(agent),
            "text": "",
            "done": False,
            "error": None,
            "usage": None,
            "abort": threading.Event(),
        }
    threading.Thread(target=_stream_run, args=(run_id, agent, message), daemon=True).start()
    return {"run_id": run_id, "session_id": _session_id(agent), "agent": agent["name"]}


def reset_chat(agent_name: str) -> dict:
    agents, _ = load_agents()
    agent = next((a for a in agents if a["name"] == agent_name), None)
    if agent is None:
        raise ValueError("Unknown agent")
    try:
        req = urllib.request.Request(
            f"{agent['root_url']}/api/sessions/{_session_id(agent)}",
            headers=_headers(agent["key"]),
            method="DELETE",
        )
        urllib.request.urlopen(req, timeout=HTTP_TIMEOUT)
    except Exception:
        pass
    return {"ok": True}


# -------------------------------------------------------------------- server


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "HermesHubBridge/1.0"

    def log_message(self, *args) -> None:  # silence
        pass

    def _send(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = _int(self.headers.get("Content-Length"))
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._send({"ok": True})

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            self._send({"ok": True})
            return
        if path == "/state":
            ensure_refresh()
            self._send(current_state())
            return
        if path == "/chat/poll":
            query = self.path.split("?", 1)[1] if "?" in self.path else ""
            run_id = ""
            for part in query.split("&"):
                if part.startswith("run_id="):
                    run_id = part[len("run_id="):]
            with _runs_lock:
                run = _runs.get(run_id)
                if run is None:
                    self._send({"done": True, "error": "Unknown run", "text": ""})
                    return
                payload = {
                    "text": run["text"],
                    "done": run["done"],
                    "error": run["error"],
                    "usage": run["usage"],
                    "session_id": run["session_id"],
                }
                if run["done"]:
                    _runs.pop(run_id, None)
            self._send(payload)
            return
        self._send({"error": "not found"}, 404)

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        body = self._read_json()
        if path == "/refresh":
            ensure_refresh(force=True)
            self._send({"ok": True})
            return
        if path == "/chat":
            message = str(body.get("message", "")).strip()
            if not message:
                self._send({"error": "empty message"}, 400)
                return
            try:
                self._send(start_chat(str(body.get("agent", "")), message))
            except ValueError as exc:
                self._send({"error": str(exc)}, 400)
            return
        if path == "/chat/stop":
            with _runs_lock:
                run = _runs.get(str(body.get("run_id", "")))
                if run:
                    run["abort"].set()
                    run["done"] = True
            self._send({"ok": True})
            return
        if path == "/chat/reset":
            try:
                self._send(reset_chat(str(body.get("agent", ""))))
            except ValueError as exc:
                self._send({"error": str(exc)}, 400)
            return
        if path == "/shutdown":
            self._send({"ok": True})
            _shutdown.set()
            return
        self._send({"error": "not found"}, 404)


def _ask_existing_to_stop() -> None:
    try:
        req = urllib.request.Request(
            f"http://{HOST}:{PORT}/shutdown",
            data=b"{}",
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass


def _check() -> int:
    """One-shot discovery report — `python3 bridge.py --check`.

    Starts no server. Prints where agents came from and whether each one answers,
    so "my widget is empty" has an answer instead of a shrug.
    """
    agents, default = load_agents()
    print("Hermes Hub — agent discovery")
    print(f"  source : {_discovery['source']}")
    print(f"  detail : {_discovery['detail']}")
    if not agents:
        print("  agents : NONE")
        print()
        print(f"  {_discovery['hint']}")
        return 1

    print(f"  agents : {len(agents)}  (default: {default})")
    print()
    offline = 0
    for agent in agents:
        health = agent_health(agent)
        if not health.get("ok"):
            offline += 1
        print(
            f"    {agent['name']:<16} {agent['base_url']:<36} "
            f"key={'set' if agent['key'] else 'MISSING':<8} "
            f"{'ok' if health.get('ok') else 'OFFLINE'}"
        )
    print()
    if offline:
        print(f"{offline} agent(s) did not answer. The widget shows them as offline")
        print("until they respond — check that Hermes is running on that host.")
        return 0
    print("All agents answered. The widget has everything it needs.")
    return 0


def main() -> None:
    ensure_refresh()
    server = None
    for attempt in range(4):
        try:
            server = ThreadingHTTPServer((HOST, PORT), Handler)
            break
        except OSError:
            if attempt == 0:
                _ask_existing_to_stop()
            time.sleep(0.5)
    if server is None:
        print(f"hermes-hub bridge: cannot bind {HOST}:{PORT}", file=sys.stderr)
        raise SystemExit(1)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    _shutdown.wait()
    server.shutdown()


if __name__ == "__main__":
    if "--check" in sys.argv:
        raise SystemExit(_check())
    main()
