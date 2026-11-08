#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$root"

patterns=(
  'gh[pousr]_[A-Za-z0-9_]{20,}'
  'Bearer[[:space:]]+[A-Za-z0-9._-]{20,}'
  '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
  "account_number[^[:cntrl:]]{0,8}[=:][[:space:]]*['\"][A-Za-z0-9-]{6,}"
  "token[^[:cntrl:]]{0,8}[=:][[:space:]]*['\"][A-Za-z0-9._-]{20,}"
)

failed=0
for pattern in "${patterns[@]}"; do
  if grep -RInE --exclude-dir=.git --exclude='check-secrets.sh' -e "$pattern" .; then
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "Обнаружен возможный секрет." >&2
  exit 1
fi
echo "Секреты и пользовательские токены не обнаружены."
