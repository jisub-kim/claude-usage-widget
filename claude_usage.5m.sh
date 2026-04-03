#!/bin/bash
# Claude Usage Monitor for SwiftBar
# 세션 한도%·주간 한도%·리셋 시간: Anthropic API 헤더 (Keychain accessToken 사용)
# 오늘·주간 토큰: ~/.claude/projects/**/*.jsonl 직접 파싱

TODAY=$(date +%Y-%m-%d)

# ─── 1. API ping → 한도/리셋 헤더 ──────────────────
get_api_headers() {
  ACCESS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
  [ -z "$ACCESS" ] && return

  curl -sf -D - -o /dev/null \
    -X POST "https://api.anthropic.com/v1/messages" \
    -H "Authorization: Bearer $ACCESS" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/2.0.37" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"x"}]}' 2>/dev/null
}

parse_header() { echo "$1" | grep -i "^$2:" | awk '{print $2}' | tr -d '\r\n'; }

# ─── 2. JSONL 파싱 → 토큰 집계 ─────────────────────
get_token_counts() {
  python3 - <<EOF
import os, json, datetime

projects_dir = os.path.expanduser('~/.claude/projects')
today = '$TODAY'
week_ago = (datetime.date.fromisoformat(today) - datetime.timedelta(days=7)).isoformat()

today_tok = 0
week_tok = 0

for root, dirs, files in os.walk(projects_dir):
    for fname in files:
        if not fname.endswith('.jsonl'):
            continue
        fpath = os.path.join(root, fname)
        try:
            with open(fpath, 'r', errors='ignore') as f:
                for line in f:
                    try:
                        obj = json.loads(line.strip())
                        if obj.get('type') != 'assistant':
                            continue
                        ts = obj.get('timestamp', '')[:10]
                        if ts < week_ago:
                            continue
                        u = obj.get('message', {}).get('usage', {})
                        tok = u.get('input_tokens', 0) + u.get('output_tokens', 0)
                        if ts == today:
                            today_tok += tok
                        if ts >= week_ago:
                            week_tok += tok
                    except Exception:
                        pass
        except Exception:
            pass

print(today_tok, week_tok)
EOF
}

# ─── 3. 포맷 헬퍼 ───────────────────────────────────
fmt_pct() {
  python3 -c "print(int(float('${1:-0}') * 100))" 2>/dev/null || echo "?"
}

fmt_reset() {
  python3 -c "
import datetime
e = float('${1:-0}')
if e <= 0:
    print('?')
else:
    diff = datetime.datetime.fromtimestamp(e) - datetime.datetime.now()
    s = int(diff.total_seconds())
    if s <= 0:
        print('리셋됨')
    else:
        h, r = divmod(s, 3600)
        m = r // 60
        d, h = divmod(h, 24)
        if d > 0:
            print(f'{d}d{h}h')
        else:
            print(f'{h}h{m}m')
" 2>/dev/null || echo "?"
}

fmt_reset_kst() {
  python3 -c "
import datetime, zoneinfo
e = float('${1:-0}')
if e <= 0:
    print('?')
else:
    kst = zoneinfo.ZoneInfo('Asia/Seoul')
    dt = datetime.datetime.fromtimestamp(e, tz=kst)
    print(dt.strftime('%m/%d(%a) %H:%M KST'))
" 2>/dev/null || echo "?"
}

fmt_tokens() {
  python3 -c "
n = $1
if n >= 1_000_000:
    print(f'{n/1_000_000:.1f}M')
elif n >= 1_000:
    print(f'{n/1_000:.0f}K')
else:
    print(n)
" 2>/dev/null || echo "?"
}

# ─── 실행 ───────────────────────────────────────────
HDRS=$(get_api_headers)
TOKEN_DATA=$(get_token_counts)

TODAY_TOK=$(echo "$TOKEN_DATA" | awk '{print $1}')
WEEK_TOK=$(echo "$TOKEN_DATA" | awk '{print $2}')

S_PCT=$(parse_header "$HDRS" "anthropic-ratelimit-unified-5h-utilization")
S_RST=$(parse_header "$HDRS" "anthropic-ratelimit-unified-5h-reset")
S_STS=$(parse_header "$HDRS" "anthropic-ratelimit-unified-5h-status")
W_PCT=$(parse_header "$HDRS" "anthropic-ratelimit-unified-7d-utilization")
W_RST=$(parse_header "$HDRS" "anthropic-ratelimit-unified-7d-reset")

S_PCT_N=$(fmt_pct "$S_PCT")
W_PCT_N=$(fmt_pct "$W_PCT")
S_RST_F=$(fmt_reset "$S_RST")
W_RST_F=$(fmt_reset "$W_RST")
S_RST_KST=$(fmt_reset_kst "$S_RST")
W_RST_KST=$(fmt_reset_kst "$W_RST")

# ─── SwiftBar 출력 ───────────────────────────────────
echo "${S_PCT_N}%(${S_RST_F})·${W_PCT_N}%(${W_RST_F})"
echo "---"
echo "🕓 세션(5h)  ${S_PCT_N}%   리셋 ${S_RST_KST}"
echo "📅 주간(7d)  ${W_PCT_N}%   리셋 ${W_RST_KST}"
echo "---"
echo "오늘 토큰   $(fmt_tokens ${TODAY_TOK:-0})"
echo "이번 주 토큰  $(fmt_tokens ${WEEK_TOK:-0})"
echo "---"
echo "새로고침 | refresh=true"
