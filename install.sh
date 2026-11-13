#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
user_bin="$HOME/.local/bin"
mkdir -p "$user_bin"

add_path() {
  local profile="$1"
  local line='export PATH="$HOME/.local/bin:$PATH"'
  touch "$profile"
  if ! grep -Fq '$HOME/.local/bin' "$profile"; then
    printf '\n# VPN MIR CLI\n%s\n' "$line" >> "$profile"
  fi
}

case "$(uname -s)" in
  Darwin)
    target="$user_bin/vpnmir"
    if [[ "$(uname -m)" == "arm64" && -x "$repo_dir/dist/vpnmir-macos-arm64" ]]; then
      install -m 0755 "$repo_dir/dist/vpnmir-macos-arm64" "$target"
    else
      command -v xcrun >/dev/null || { echo "Нужны Xcode Command Line Tools: xcode-select --install" >&2; exit 1; }
      cache_dir="$(mktemp -d)"
      trap 'rm -rf "$cache_dir"' EXIT
      CLANG_MODULE_CACHE_PATH="$cache_dir/clang" SWIFT_MODULECACHE_PATH="$cache_dir/swift" \
        xcrun swiftc -O -framework NetworkExtension -framework CryptoKit \
        "$repo_dir/src/macos/vpnmir.swift" -o "$target"
    fi
    codesign --force --sign - "$target" >/dev/null 2>&1 || true
    ln -sf "$target" "$user_bin/vpn"
    add_path "$HOME/.zshrc"
    ;;
  Linux)
    command -v python3 >/dev/null || { echo "Не найден python3." >&2; exit 1; }
    command -v gh >/dev/null || { echo "Нужен GitHub CLI (gh)." >&2; exit 1; }
    command -v unzip >/dev/null || { echo "Нужен unzip." >&2; exit 1; }
    app_dir="$HOME/.local/lib/vpnmir"
    venv="$app_dir/venv"
    mkdir -p "$app_dir"
    install -m 0644 "$repo_dir/src/linux/vpnmir.py" "$app_dir/vpnmir.py"
    python3 -m venv "$venv"
    "$venv/bin/python" -m pip install --disable-pip-version-check --quiet --upgrade pip
    "$venv/bin/python" -m pip install --disable-pip-version-check --quiet 'cryptography>=42,<47'
    if [[ ! -x "$app_dir/xray" ]]; then
      case "$(uname -m)" in
        x86_64|amd64) asset='Xray-linux-64.zip' ;;
        aarch64|arm64) asset='Xray-linux-arm64-v8a.zip' ;;
        *) echo "Архитектура Linux не поддерживается: $(uname -m)" >&2; exit 1 ;;
      esac
      download_dir="$(mktemp -d)"
      trap 'rm -rf "$download_dir"' EXIT
      gh release download --repo XTLS/Xray-core --pattern "$asset" --dir "$download_dir"
      unzip -q "$download_dir/$asset" xray -d "$download_dir"
      install -m 0755 "$download_dir/xray" "$app_dir/xray"
    fi
    cat > "$user_bin/vpnmir" <<EOF
#!/bin/sh
export VPNMIR_XRAY="$app_dir/xray"
exec "$venv/bin/python" "$app_dir/vpnmir.py" "\$@"
EOF
    chmod 0755 "$user_bin/vpnmir"
    ln -sf "$user_bin/vpnmir" "$user_bin/vpn"
    if [[ "${SHELL:-}" == *zsh ]]; then add_path "$HOME/.zshrc"; else add_path "$HOME/.bashrc"; fi
    ;;
  *)
    echo "Поддерживаются только macOS и Linux." >&2
    exit 1
    ;;
esac

echo "Установлено: $user_bin/vpnmir"
echo "Откройте новый терминал или выполните: export PATH=\"\$HOME/.local/bin:\$PATH\""
echo "Справка: vpnmir h"
echo "Короткое имя: vpn"
