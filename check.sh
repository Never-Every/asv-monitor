#!/usr/bin/env bash
# Мониторинг ASV-Link: проверяет адреса из секрета TARGETS и пишет в Telegram,
# только когда состояние меняется (упало / поднялось).
# Формат TARGETS — по строке на проверку:  Имя|https://адрес   или   Имя|tcp://хост:порт
set -u

STATE_FILE="${STATE_FILE:-state/status.txt}"
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

tg() {
  [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT:-}" ]] && { echo "[нет TG_TOKEN/TG_CHAT] $1"; return; }
  curl -s -o /dev/null --max-time 20 \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT}" \
    --data-urlencode "text=$1" || echo "не удалось отправить в Telegram"
}

# Одна попытка: печатает OK или причину сбоя
probe() {
  local t=$1
  if [[ $t == tcp://* ]]; then
    local hp=${t#tcp://}
    if timeout 10 bash -c "exec 3<>/dev/tcp/${hp%:*}/${hp##*:}" 2>/dev/null; then
      echo OK
    else
      echo "нет соединения"
    fi
  else
    local c
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$t")
    if [[ $c == 200 ]]; then echo OK
    elif [[ $c == 000 ]]; then echo "нет ответа"
    else echo "код $c"
    fi
  fi
}

# Три попытки с паузой, чтобы не тревожить из-за разового сбоя сети
check() {
  local r
  for i in 1 2 3; do
    r=$(probe "$1")
    [[ $r == OK ]] && { echo OK; return; }
    [[ $i -lt 3 ]] && sleep 20
  done
  echo "$r"
}

new_state=""
alerts=""
report=""
n=0

while IFS='|' read -r name target; do
  name=$(echo "$name" | xargs)
  target=$(echo "${target:-}" | xargs)
  [[ -z $name || -z $target ]] && continue
  n=$((n + 1))

  r=$(check "$target")
  old=$(grep -F "${name}|" "$STATE_FILE" | head -1 | cut -d'|' -f2)
  [[ -z $old ]] && old=OK

  if [[ $r != OK && $old == OK ]]; then
    alerts+="🔴 ${name} — не отвечает (${r})"$'\n'
  elif [[ $r == OK && $old != OK ]]; then
    alerts+="🟢 ${name} — снова работает"$'\n'
  fi

  if [[ $r == OK ]]; then report+="🟢 ${name}"$'\n'; else report+="🔴 ${name} — ${r}"$'\n'; fi
  new_state+="${name}|${r}"$'\n'
  echo "${name}: ${r}"
done <<< "${TARGETS:-}"

if [[ $n -eq 0 ]]; then
  echo "TARGETS пуст — нечего проверять"
  exit 1
fi

printf '%s' "$new_state" > "$STATE_FILE"

[[ -n $alerts ]] && tg "ASV-Link${alerts:+$'\n'}${alerts}"

if [[ "${HEARTBEAT:-0}" == 1 ]]; then
  tg "Мониторинг ASV-Link работает. Сейчас:"$'\n'"${report}"
fi

exit 0
