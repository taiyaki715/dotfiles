#!/usr/bin/env bash

input=$(cat)

make_bar() {
  local pct=$1
  local filled
  filled=$(echo "$pct" | awk '{printf "%d", int($1/10)}')
  if [ "$filled" -gt 10 ]; then
    filled=10
  elif [ "$filled" -lt 0 ]; then
    filled=0
  fi
  local empty=$((10 - filled))
  local bar=""
  local i
  for ((i=0; i<filled; i++)); do
    bar="${bar}█"
  done
  for ((i=0; i<empty; i++)); do
    bar="${bar}░"
  done
  echo "$bar"
}

ctx=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

out=""

if [ -n "$ctx" ]; then
  pct_ctx=$(printf '%.0f' "$ctx")
  out="ctx $(make_bar "$ctx") ${pct_ctx}%"
fi

if [ -n "$out" ]; then
  out="$out | "
fi
if [ -n "$five" ]; then
  pct_five=$(printf '%.0f' "$five")
  out="${out}5h $(make_bar "$five") ${pct_five}%"
else
  out="${out}5h $(make_bar 0) ?%"
fi

if [ -n "$out" ]; then
  out="$out | "
fi
if [ -n "$week" ]; then
  pct_week=$(printf '%.0f' "$week")
  out="${out}7d $(make_bar "$week") ${pct_week}%"
else
  out="${out}7d $(make_bar 0) ?%"
fi

echo "$out"
