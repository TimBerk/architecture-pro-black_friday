#!/usr/bin/env bash
set -euo pipefail

BASE="${1:-http://localhost:8080}"
COLL="${2:-helloDoc}"              # имя коллекции
WARMUP="${3:-2}"                   # сколько прогревочных запросов
COUNT="${4:-30}"                   # сколько измеряемых запросов
DELAY="${5:-0.05}"                 # пауза между запросами, сек
THRESH_MS="${6:-100}"              # порог для SLA

URL="${BASE}/${COLL}/users"

echo "[load] URL=${URL} warmup=${WARMUP} count=${COUNT} delay=${DELAY}s thresh=${THRESH_MS}ms"

# прогрев
for ((i=1;i<=WARMUP;i++)); do
  curl -s -o /dev/null -w "warmup#$i code=%{http_code} t=%{time_total}s\n" "$URL"
  sleep "$DELAY"
done

# измерение “второй и последующих”
ok=0; sum=0; best=99999; worst=0; over=0
for ((i=1;i<=COUNT;i++)); do
  line="$(curl -s -o /dev/null -w "%{http_code} %{time_total}\n" "$URL")"
  code="${line%% *}"
  tsec="${line##* }"
  tms="$(awk -v t="$tsec" 'BEGIN{printf("%.2f", t*1000)}')"
  echo "req#$i code=$code t=${tms}ms"
  if [[ "$code" == "200" ]]; then
    ok=$((ok+1))
    sum="$(awk -v a="$sum" -v b="$tms" 'BEGIN{printf("%.2f", a+b)}')"
    best="$(awk -v a="$best" -v b="$tms" 'BEGIN{print (b<a)?b:a}')"
    worst="$(awk -v a="$worst" -v b="$tms" 'BEGIN{print (b>a)?b:a}')"
    awk -v v="$tms" -v th="$THRESH_MS" 'BEGIN{if (v>th) exit 1}' || over=$((over+1))
  fi
  sleep "$DELAY"
done

avg="$(awk -v s="$sum" -v n="$ok" 'BEGIN{if(n>0) printf("%.2f", s/n); else print "NaN"}')"
echo "[load] steady: ok=$ok/$COUNT avg=${avg}ms best=${best}ms worst=${worst}ms over>${THRESH_MS}ms=$over"
# ненулевой exit при нарушении порога
if (( over > 0 )); then
  echo "[load] FAIL: some steady requests exceed ${THRESH_MS}ms"
  exit 2
else
  echo "[load] PASS: all steady requests under ${THRESH_MS}ms"
fi
