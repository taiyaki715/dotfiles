#!/usr/bin/env bash
#
# ~/.claude 配下の自作ファイルを、このリポジトリへのシンボリックリンクに差し替える。
#
# ~/.claude には会話ログ (history.jsonl, projects/, sessions/) が同居しているため、
# ディレクトリ全体ではなく管理対象だけを個別にリンクする。
#
# 冪等。Claude Code が settings.json を書き換えてリンクが外れた場合も再実行で戻せる。

set -uo pipefail

src_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dst_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# 管理対象: <このリポジトリ内の相対パス>
targets=(
  settings.json
  statusline-command.sh
  CLAUDE.md
  hooks
  skills
)

mkdir -p "$dst_dir" || exit 1

conflicts=()

for rel in "${targets[@]}"; do
  src="$src_dir/$rel"
  dst="$dst_dir/$rel"

  if [[ ! -e "$src" ]]; then
    echo "skip: $rel はリポジトリ側に存在しません" >&2
    continue
  fi

  if [[ -e "$dst" && ! -L "$dst" ]]; then
    # 実ファイル/実ディレクトリが居座っている。
    # 中身がリポジトリ側と同一なら失うものはないので差し替える。
    # 差異があるならローカルの変更を消しかねないので触らない。
    if diff -r -q "$src" "$dst" >/dev/null 2>&1; then
      rm -rf "$dst" || exit 1
    else
      conflicts+=("$rel")
      continue
    fi
  fi

  ln -sfn "$src" "$dst" || exit 1
done

if [[ ${#conflicts[@]} -gt 0 ]]; then
  echo >&2
  echo "中断: 次の項目はリポジトリ側と内容が異なる実ファイルです。上書きしませんでした:" >&2
  for rel in "${conflicts[@]}"; do
    echo "  $dst_dir/$rel" >&2
  done
  echo >&2
  echo "diff で差分を確認し、必要な内容を $src_dir へ取り込んでから" >&2
  echo "$dst_dir 側を削除して再実行してください。" >&2
  exit 1
fi

echo "リンクを作成しました:"
for rel in "${targets[@]}"; do
  [[ -L "$dst_dir/$rel" ]] && printf '  %-24s -> %s\n' "$rel" "$(readlink "$dst_dir/$rel")"
done
