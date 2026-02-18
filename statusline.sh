#!/usr/bin/env bash
# Claude Code statusline — context + API usage (5h/weekly/extra)
set -euo pipefail

INPUT=$(cat)

# ── Parse stdin JSON ──
MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "Unknown"' 2>/dev/null) || MODEL="Unknown"
CTX_SIZE=$(echo "$INPUT" | jq -r '.context_window.context_window_size // 200000' 2>/dev/null) || CTX_SIZE=200000
USED_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null) || USED_PCT=0
REMAIN_PCT=$(echo "$INPUT" | jq -r '.context_window.remaining_percentage // 100' 2>/dev/null) || REMAIN_PCT=100
IN_TOK=$(echo "$INPUT" | jq -r '.context_window.current_usage.input_tokens // 0' 2>/dev/null) || IN_TOK=0
OUT_TOK=$(echo "$INPUT" | jq -r '.context_window.current_usage.output_tokens // 0' 2>/dev/null) || OUT_TOK=0
CACHE_C=$(echo "$INPUT" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0' 2>/dev/null) || CACHE_C=0
CACHE_R=$(echo "$INPUT" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0' 2>/dev/null) || CACHE_R=0
COST=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null) || COST=0
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""

WINDOW_USED=$((IN_TOK + OUT_TOK + CACHE_C + CACHE_R))

# ── Thinking ──
THINKING="Off"
T=$(jq -r '.alwaysThinkingEnabled // false' ~/.claude/settings.json 2>/dev/null) || true
[ "$T" = "true" ] && THINKING="On"

# ── Helpers ──
fmt_short() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then printf "%.1fM" "$(echo "scale=1; $n/1000000" | bc)"
  elif [ "$n" -ge 1000 ]; then printf "%dk" "$((n/1000))"
  else echo "$n"; fi
}
bar() {
  local pct="${1%.*}"; pct=${pct:-0}
  [ "$pct" -gt 100 ] && pct=100
  local filled=$((pct / 10))
  local empty=$((10 - filled))
  local b=""
  for ((i=0;i<filled;i++)); do b+="●"; done
  for ((i=0;i<empty;i++)); do b+="○"; done
  echo "$b"
}
clr() {
  local v="${1%.*}"; v=${v:-0}
  if [ "$v" -lt 50 ]; then printf '\033[32m'
  elif [ "$v" -lt 75 ]; then printf '\033[33m'
  else printf '\033[31m'; fi
}

# ── Colors ──
C='\033[36m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; D='\033[2m'; B='\033[1m'; X='\033[0m'
M='\033[35m'  # magenta for extra
UI=${USED_PCT%.*}; UI=${UI:-0}
RI=${REMAIN_PCT%.*}; RI=${RI:-0}

# ── API Usage (cached 60s) ──
CACHE_FILE="/tmp/.claude-usage-cache.json"
CACHE_TTL=5
FIVE_PCT=0; FIVE_RESET=""; SEVEN_PCT=0; SEVEN_RESET=""
EXTRA_ENABLED="false"; EXTRA_USED=""; EXTRA_LIMIT=""; EXTRA_PCT=0

fetch_usage() {
  local token
  token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken' 2>/dev/null) || return 1
  [ -z "$token" ] && return 1
  local resp
  resp=$(curl -s --max-time 3 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" 2>/dev/null) || return 1
  # Validate JSON
  echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1 || return 1
  # Write cache with timestamp
  jq -n --argjson data "$resp" --arg ts "$(date +%s)" '{data: $data, ts: $ts}' > "$CACHE_FILE" 2>/dev/null
}

# Check cache freshness
NEED_FETCH=true
if [ -f "$CACHE_FILE" ]; then
  CACHE_TS=$(jq -r '.ts // "0"' "$CACHE_FILE" 2>/dev/null) || CACHE_TS=0
  NOW=$(date +%s)
  if [ $((NOW - CACHE_TS)) -lt $CACHE_TTL ]; then
    NEED_FETCH=false
  fi
fi

# Fetch in background if stale (don't block statusline)
if [ "$NEED_FETCH" = true ]; then
  fetch_usage &
fi

# Read from cache (might be slightly stale on first run)
if [ -f "$CACHE_FILE" ]; then
  USAGE_DATA=$(jq -r '.data' "$CACHE_FILE" 2>/dev/null) || USAGE_DATA="{}"
  FIVE_PCT=$(echo "$USAGE_DATA" | jq -r '.five_hour.utilization // 0' 2>/dev/null) || FIVE_PCT=0
  FIVE_RESET=$(echo "$USAGE_DATA" | jq -r '.five_hour.resets_at // ""' 2>/dev/null) || FIVE_RESET=""
  SEVEN_PCT=$(echo "$USAGE_DATA" | jq -r '.seven_day.utilization // 0' 2>/dev/null) || SEVEN_PCT=0
  SEVEN_RESET=$(echo "$USAGE_DATA" | jq -r '.seven_day.resets_at // ""' 2>/dev/null) || SEVEN_RESET=""
  EXTRA_ENABLED=$(echo "$USAGE_DATA" | jq -r '.extra_usage.is_enabled // false' 2>/dev/null) || EXTRA_ENABLED="false"
  EXTRA_USED=$(echo "$USAGE_DATA" | jq -r '.extra_usage.used_credits // 0' 2>/dev/null) || EXTRA_USED="0"
  EXTRA_LIMIT=$(echo "$USAGE_DATA" | jq -r '.extra_usage.monthly_limit // 0' 2>/dev/null) || EXTRA_LIMIT="0"
  EXTRA_PCT=$(echo "$USAGE_DATA" | jq -r '.extra_usage.utilization // 0' 2>/dev/null) || EXTRA_PCT=0
fi

# ── Format reset times ──
iso_to_epoch() {
  python3 -c "
from datetime import datetime
s = '$1'
try:
    dt = datetime.fromisoformat(s)
    print(int(dt.timestamp()))
except:
    print(0)
" 2>/dev/null || echo "0"
}

fmt_reset() {
  local iso="$1"
  [ -z "$iso" ] && echo "?" && return
  local epoch
  epoch=$(iso_to_epoch "$iso")
  [ "$epoch" = "0" ] && { echo "?"; return; }
  # %-l:%-M + lowercase am/pm
  local raw
  raw=$(date -r "$epoch" "+%l:%M%p" 2>/dev/null) || { echo "?"; return; }
  # Trim leading space, lowercase am/pm
  echo "$raw" | sed 's/^ //;s/AM/am/;s/PM/pm/'
}

fmt_reset_date() {
  local iso="$1"
  [ -z "$iso" ] && echo "?" && return
  local epoch
  epoch=$(iso_to_epoch "$iso")
  [ "$epoch" = "0" ] && { echo "?"; return; }
  local raw
  raw=$(date -r "$epoch" "+%b %e, %l:%M%p" 2>/dev/null) || { echo "?"; return; }
  echo "$raw" | sed 's/  / /g;s/^ //;s/AM/am/;s/PM/pm/'
}

FIVE_RESET_STR=$(fmt_reset "$FIVE_RESET")
SEVEN_RESET_STR=$(fmt_reset_date "$SEVEN_RESET")

# Integer versions for bar/clr
FI=${FIVE_PCT%.*}; FI=${FI:-0}
SI=${SEVEN_PCT%.*}; SI=${SI:-0}
EI=${EXTRA_PCT%.*}; EI=${EI:-0}

# ── Line 1: Model | context | thinking ──
echo -e "${C}${MODEL}${X} ${D}|${X} $(fmt_short $WINDOW_USED) / $(fmt_short $CTX_SIZE) ${D}|${X} $(clr $UI)${UI}% used${X} ${D}|${X} ${G}${RI}% remain${X} ${D}|${X} thinking: ${B}${THINKING}${X}"

# ── Line 2: current (5h) | weekly (7d) | extra ──
LINE2="current: $(clr $FI)$(bar $FI)${X} ${FI}% ${D}|${X} weekly: $(clr $SI)$(bar $SI)${X} ${SI}%"
if [ "$EXTRA_ENABLED" = "true" ]; then
  EXTRA_USED_FMT=$(printf '%.2f' "$EXTRA_USED" 2>/dev/null || echo "$EXTRA_USED")
  EXTRA_LIMIT_FMT=$(printf '%.0f' "$EXTRA_LIMIT" 2>/dev/null || echo "$EXTRA_LIMIT")
  LINE2="${LINE2} ${D}|${X} extra: $(clr $EI)$(bar $EI)${X} ${M}\$${EXTRA_USED_FMT}/\$${EXTRA_LIMIT_FMT}${X}"
fi
echo -e "$LINE2"

# ── Line 3: resets | cost | branch ──
BRANCH=""
[ -n "$CWD" ] && [ -d "$CWD/.git" ] && BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null) || true
BRANCH_PART=""
[ -n "${BRANCH:-}" ] && BRANCH_PART=" ${D}|${X} ${C}⎇ ${BRANCH}${X}"

echo -e "${D}resets${X} ${Y}${FIVE_RESET_STR}${X} ${D}|${X} ${D}resets${X} ${Y}${SEVEN_RESET_STR}${X} ${D}|${X} ${D}cost:${X} ${Y}\$$(printf '%.2f' "$COST")${X}${BRANCH_PART}"

# Wait for background fetch if running
wait 2>/dev/null || true