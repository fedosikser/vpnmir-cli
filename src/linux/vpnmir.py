#!/usr/bin/env python3
"""Unofficial VPN MIR CLI for Linux. Secrets stay in ~/.config/vpnmir (0600)."""

from __future__ import annotations

import base64
import getpass
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

API_BASE = "https://vpnmirapis.com"
LOCATIONS_URL = f"{API_BASE}/api/v1/locations.json?tier=patron"
PROFILE_KEY = b"QAM1Ta94n2WSgZAN9KoW67objsv19lzs"
RENEW_SECONDS = 59 * 60
HOME = pathlib.Path.home()
CONFIG_DIR = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "vpnmir"
CACHE_DIR = pathlib.Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "vpnmir"
STATE_DIR = pathlib.Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "vpnmir"
ACCOUNT_FILE = CONFIG_DIR / "account.json"
SESSION_FILE = CONFIG_DIR / "session.json"
SETTINGS_FILE = CONFIG_DIR / "settings.json"
CACHE_FILE = CACHE_DIR / "locations.json"
STATE_FILE = STATE_DIR / "state.json"
XRAY_CONFIG = STATE_DIR / "xray.json"
XRAY_PID = STATE_DIR / "xray.pid"
WATCHDOG_PID = STATE_DIR / "watchdog.pid"
LOG_FILE = STATE_DIR / "vpnmir.log"


class CLIError(RuntimeError):
    pass


def ensure_dirs() -> None:
    for directory in (CONFIG_DIR, CACHE_DIR, STATE_DIR):
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        directory.chmod(0o700)


def secure_json(path: pathlib.Path, value: object) -> None:
    ensure_dirs()
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temp.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
    temp.chmod(0o600)
    temp.replace(path)


def read_json(path: pathlib.Path, default=None):
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def request_json(url: str, *, method: str = "GET", body=None, token: str | None = None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("User-Agent", "vpnmir-cli/2.0")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise CLIError(f"API VPN MIR вернул HTTP {error.code}.") from error
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise CLIError(f"Ошибка API VPN MIR: {error}") from error


def account_number() -> str:
    account = read_json(ACCOUNT_FILE, {})
    value = str(account.get("account_number", "")).strip()
    if not value:
        raise CLIError("Аккаунт не настроен. Выполните: vpnmir i")
    return value


def login(force: bool = False) -> str:
    session = read_json(SESSION_FILE, {})
    if not force and session.get("token"):
        return session["token"]
    result = request_json(f"{API_BASE}/api/v1/login", method="POST", body={"account_number": account_number()})
    token = result.get("token")
    if not token:
        raise CLIError("API не вернул токен активации.")
    secure_json(SESSION_FILE, {"token": token})
    return token


def configure_login() -> None:
    value = getpass.getpass("Номер аккаунта VPN MIR (ввод скрыт): ").strip()
    if not value:
        raise CLIError("Номер аккаунта не может быть пустым.")
    secure_json(ACCOUNT_FILE, {"account_number": value})
    try:
        SESSION_FILE.unlink()
    except FileNotFoundError:
        pass
    login(force=True)
    print("Аккаунт сохранён локально с правами 0600; токен в репозиторий не передаётся.")


def fetch_locations() -> list[dict]:
    try:
        rows = request_json(LOCATIONS_URL)
        secure_json(CACHE_FILE, rows)
        return rows
    except CLIError:
        cached = read_json(CACHE_FILE)
        if cached:
            print("Предупреждение: используется локальный кеш.", file=sys.stderr)
            return cached
        raise


def load_locations(refresh: bool = False) -> list[dict]:
    if not refresh and CACHE_FILE.exists() and time.time() - CACHE_FILE.stat().st_mtime < 6 * 3600:
        cached = read_json(CACHE_FILE)
        if cached:
            return cached
    return fetch_locations()


def find_location(rows: list[dict], query: str) -> dict:
    query_folded = query.casefold()
    exact = [row for row in rows if str(row["id"]) == query or row["code"].casefold() == query_folded]
    matches = exact or [row for row in rows if query_folded in f"{row['name']} {row['city_name']}".casefold()]
    if not matches:
        raise CLIError(f"Локация «{query}» не найдена. Выполните: vpnmir l")
    if len(matches) != 1:
        raise CLIError("Найдено несколько локаций. Укажите ID.")
    return matches[0]


def choose_server(location: dict, requested: int | None = None, include_offline: bool = False) -> dict:
    servers = [item for item in location["servers"] if all(item.get(key) for key in ("hash", "iv", "tag"))]
    if requested is not None:
        servers = [item for item in servers if item["id"] == requested]
    if not include_offline:
        online = [item for item in servers if item.get("is_online") is not False]
        if online:
            servers = online
    if not servers:
        raise CLIError("Подходящий сервер не найден. Добавьте --try-offline.")
    return sorted(servers, key=lambda item: (item.get("is_online") is False, item.get("load", 10**9)))[0]


def decrypt_config(server: dict) -> dict:
    try:
        ciphertext = base64.b64decode(server["hash"])
        nonce = base64.b64decode(server["iv"])
        tag = base64.b64decode(server["tag"])
        config = json.loads(AESGCM(PROFILE_KEY).decrypt(nonce, ciphertext + tag, None))
    except Exception as error:
        raise CLIError("Не удалось расшифровать профиль сервера.") from error
    if not config.get("outbounds"):
        raise CLIError("В профиле отсутствует конфигурация VPN.")
    return config


def pid_alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except ProcessLookupError:
        return False


def read_pid(path: pathlib.Path) -> int:
    try:
        return int(path.read_text().strip())
    except (FileNotFoundError, ValueError, OSError):
        return 0


def stop_pid(path: pathlib.Path) -> None:
    pid = read_pid(path)
    if pid_alive(pid):
        try:
            os.killpg(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            try:
                os.kill(pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
        for _ in range(30):
            if not pid_alive(pid):
                break
            time.sleep(0.1)
    path.unlink(missing_ok=True)


def xray_binary() -> str:
    value = os.environ.get("VPNMIR_XRAY") or shutil.which("xray")
    if not value:
        bundled = HOME / ".local/lib/vpnmir/xray"
        if bundled.exists():
            value = str(bundled)
    if not value:
        raise CLIError("Xray не найден. Повторно запустите install.sh.")
    return value


def proxy_endpoint(config: dict) -> tuple[str, int] | None:
    for inbound in config.get("inbounds", []):
        if inbound.get("protocol") == "socks":
            return str(inbound.get("listen", "127.0.0.1")), int(inbound["port"])
    return None


def start_xray(config: dict) -> None:
    ensure_dirs()
    stop_pid(XRAY_PID)
    secure_json(XRAY_CONFIG, config)
    log = LOG_FILE.open("ab", buffering=0)
    process = subprocess.Popen([xray_binary(), "run", "-c", str(XRAY_CONFIG)], stdout=log, stderr=log,
                               start_new_session=True, close_fds=True)
    XRAY_PID.write_text(str(process.pid)); XRAY_PID.chmod(0o600)
    time.sleep(1.5)
    if process.poll() is not None:
        raise CLIError(f"Xray завершился с кодом {process.returncode}. Смотрите {LOG_FILE}")


def settings() -> dict:
    value = read_json(SETTINGS_FILE, {})
    return {"enabled": bool(value.get("enabled", True)), "interval_seconds": max(60, int(value.get("interval_seconds", RENEW_SECONDS)))}


def save_settings(value: dict) -> None:
    secure_json(SETTINGS_FILE, value)


def connect_location(location: dict, server: dict, manage_watchdog: bool = True) -> None:
    config = decrypt_config(server)
    start_xray(config)
    secure_json(STATE_FILE, {"location_id": location["id"], "code": location["code"], "name": location["name"],
                             "city": location["city_name"], "server_id": server["id"], "connected_at": time.time(),
                             "proxy": proxy_endpoint(config)})
    if manage_watchdog:
        if settings()["enabled"]:
            start_watchdog()
        else:
            stop_pid(WATCHDOG_PID)
    secret = " ⚡" if server.get("is_patron_only") else ""
    print(f"Подключено: {location['name']} / {location['city_name']}, сервер {server['id']}{secret}")
    if endpoint := proxy_endpoint(config):
        print(f"SOCKS5: {endpoint[0]}:{endpoint[1]}")


def connect_saved(manage_watchdog: bool = True) -> None:
    state = read_json(STATE_FILE)
    if not state:
        raise CLIError("Последнее подключение не сохранено. Сначала выполните: vpnmir c <код>")
    location = find_location(load_locations(), str(state["location_id"]))
    server = choose_server(location, int(state["server_id"]), include_offline=True)
    connect_location(location, server, manage_watchdog)


def start_watchdog() -> None:
    stop_pid(WATCHDOG_PID)
    log = LOG_FILE.open("ab", buffering=0)
    process = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve()), "__watchdog"],
                               stdout=log, stderr=log, start_new_session=True, close_fds=True,
                               env=os.environ.copy())
    WATCHDOG_PID.write_text(str(process.pid)); WATCHDOG_PID.chmod(0o600)


def watchdog() -> None:
    while True:
        current = settings()
        if not current["enabled"]:
            return
        state = read_json(STATE_FILE)
        if not state:
            time.sleep(10)
            continue
        remaining = float(state["connected_at"]) + current["interval_seconds"] - time.time()
        if remaining > 0:
            time.sleep(min(30, max(1, remaining)))
            continue
        try:
            connect_saved(manage_watchdog=False)
        except Exception as error:
            print(f"[{datetime.now().isoformat()}] autorenew: {error}", file=sys.stderr, flush=True)
            time.sleep(60)


def renew_status() -> None:
    current = settings(); watchdog_running = pid_alive(read_pid(WATCHDOG_PID))
    print(f"Autorenew: {'включён' if current['enabled'] else 'выключен'}")
    print(f"Интервал: {current['interval_seconds'] // 60} мин.")
    print(f"Watchdog: {'работает' if watchdog_running else 'не запущен'}")
    state = read_json(STATE_FILE)
    if current["enabled"] and watchdog_running and state:
        next_run = datetime.fromtimestamp(float(state["connected_at"]) + current["interval_seconds"])
        print(f"Следующее обновление: {next_run:%d.%m.%Y %H:%M:%S}")


def print_activation(refresh: bool) -> None:
    if refresh:
        account = request_json(f"{API_BASE}/api/v1/current_user.json", token=login())
    else:
        account = request_json(f"{API_BASE}/api/v1/current_user.json", token=login())
    print(f"Активация: {'активна' if account.get('has_active_access') else 'неактивна'}")
    print(f"Безлимитное время: {'да' if account.get('has_unlimited_time_access') else 'нет'}")
    print(f"Секретные серверы ⚡: {'доступны' if account.get('has_secret_servers_access') else 'недоступны'}")


def usage() -> None:
    print("""VPN MIR CLI 2.0 для Linux

  vpnmir i|login                         настроить аккаунт (скрытый ввод)
  vpnmir c|connect [локация] [--server ID] [--try-offline]
  vpnmir d|disconnect
  vpnmir s|status
  vpnmir l|locations [--refresh]
  vpnmir v|servers <локация>
  vpnmir a|activation [--refresh]
  vpnmir t|token [--refresh]
  vpnmir r|autorenew [MINUTES]|on|off|status
  vpnmir h|help

Linux-режим запускает локальный SOCKS5-прокси Xray. Autorenew включён по умолчанию.
""")


def main(argv: list[str]) -> int:
    ensure_dirs()
    command = argv[0] if argv else "help"
    if command in ("help", "h", "-h", "--help"):
        usage()
    elif command in ("login", "i"):
        configure_login()
    elif command in ("locations", "list", "l"):
        for row in sorted(load_locations("--refresh" in argv), key=lambda item: item["id"]):
            online = sum(item.get("is_online") is not False for item in row["servers"])
            secret = "⚡" if any(item.get("is_patron_only") for item in row["servers"]) else " "
            print(f"{row['id']:3}  {row['code']:<3} {secret} {row['name']} / {row['city_name']}  {online}/{len(row['servers'])} online")
    elif command in ("servers", "v"):
        if len(argv) < 2:
            raise CLIError("Укажите локацию.")
        location = find_location(load_locations(), argv[1])
        for server in sorted(location["servers"], key=lambda item: item["id"]):
            print(f"{server['id']:5}  {'⚡' if server.get('is_patron_only') else ' '} "
                  f"{'offline*' if server.get('is_online') is False else 'online':<8} load={server.get('load', -1)}")
    elif command in ("connect", "start", "c"):
        positional = next((arg for arg in argv[1:] if not arg.startswith("--") and not arg.isdigit()), None)
        if len(argv) == 1:
            connect_saved()
        else:
            query = argv[1]
            if query.startswith("--"):
                connect_saved()
            else:
                server_id = int(argv[argv.index("--server") + 1]) if "--server" in argv else None
                location = find_location(load_locations(), query)
                connect_location(location, choose_server(location, server_id, "--try-offline" in argv))
    elif command in ("disconnect", "stop", "d"):
        stop_pid(WATCHDOG_PID); stop_pid(XRAY_PID); print("VPN MIR отключён.")
    elif command in ("status", "s"):
        running = pid_alive(read_pid(XRAY_PID)); print(f"VPN MIR/Xray: {'подключён' if running else 'отключён'}")
        state = read_json(STATE_FILE, {})
        if state:
            print(f"Выбрано: {state.get('name')} / {state.get('city')}, сервер {state.get('server_id')}")
            if state.get("proxy"):
                print(f"SOCKS5: {state['proxy'][0]}:{state['proxy'][1]}")
        renew_status()
    elif command in ("activation", "account", "a"):
        print_activation("--refresh" in argv)
    elif command in ("token", "t"):
        print(login(force="--refresh" in argv))
    elif command in ("autorenew", "renew", "r"):
        action = argv[1] if len(argv) > 1 else "status"
        if action.isdecimal():
            minutes = int(action)
            if not 1 <= minutes <= 10_080:
                raise CLIError("Интервал должен быть от 1 до 10080 минут.")
            save_settings({"enabled": True, "interval_seconds": minutes * 60})
            if pid_alive(read_pid(XRAY_PID)):
                start_watchdog()
            print(f"Autorenew включён: обновление каждые {minutes} мин.")
        elif action in ("on", "enable"):
            current = settings(); current["enabled"] = True
            save_settings(current)
            if pid_alive(read_pid(XRAY_PID)):
                start_watchdog()
            print(f"Autorenew включён: обновление каждые {current['interval_seconds'] // 60} мин.")
        elif action in ("off", "disable"):
            current = settings(); current["enabled"] = False
            save_settings(current); stop_pid(WATCHDOG_PID)
            print("Autorenew выключен.")
        elif action in ("status", "s"):
            renew_status()
        else:
            raise CLIError("Использование: vpnmir r [MINUTES]|on|off|status")
    elif command == "__watchdog":
        watchdog()
    else:
        raise CLIError(f"Неизвестная команда «{command}». Выполните: vpnmir h")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (CLIError, ValueError, IndexError) as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        raise SystemExit(1)
