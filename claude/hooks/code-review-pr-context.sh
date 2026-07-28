#!/usr/bin/env bash
#
# UserPromptExpansion hook for /code-review
#
# /code-review に PR 番号が渡されたとき、その PR の概要文・レビューコメント・
# 会話スレッド・リンクされた Issue を取得し、additionalContext として注入する。
#
# 取得方針: 件数・文字数とも上限を設けず全件取得する。
#   - 本文の切り詰めなし
#   - reviews / issue コメントは REST を --paginate で全ページ取得
#   - レビュースレッド / リンク Issue は GraphQL を --paginate で全ページ取得
#   - 唯一の例外は 1 スレッド内の返信（GraphQL のネスト接続はページ送りできないため
#     first:100 固定。1 スレッドに 100 返信は実運用で起きない想定）
#
# 失敗時の方針:
#   - PR 番号が引数にない        -> 意図した非適用。無音で exit 0
#   - PR 番号はあるが取得できない -> systemMessage(ユーザー向け) と
#                                   additionalContext(モデル向け) の両方で明示
# いずれの場合も exit 0 で返し、レビュー自体はブロックしない。
# (exit 2 はスラッシュコマンドごとブロックしてしまうため使わない)

set -uo pipefail

PAGE_SIZE=100   # 1リクエストあたりの取得件数。総数の上限ではない（全ページ辿る）

# --- 警告を返して終了する（PR 指定があるのに取得できなかった場合） -----------
warn_and_exit() {
  local msg="$1" hint="${2:-}"
  local ctx="PR #${num} が指定されましたが、前提コンテキストを取得できませんでした（${msg}）。"
  ctx+="PR の概要・既出の指摘を参照できていないため、その旨を最初にユーザーへ伝えたうえでレビューを進めてください。"
  [[ -n "$hint" ]] && ctx+=" 復旧方法: ${hint}"

  jq -n --arg sys "PR #${num} の前提コンテキストを取得できませんでした: ${msg}" --arg ctx "$ctx" \
    '{systemMessage:$sys,
      hookSpecificOutput:{hookEventName:"UserPromptExpansion",additionalContext:$ctx}}'
  exit 0
}

# --- 前提ツール --------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  # jq がないと入力 JSON のパースも出力の組み立てもできない。
  # 非ゼロ終了で stderr をユーザーに見せる（レビューは続行される）。
  echo "code-review hook: jq が見つからないため PR コンテキストを取得できません" >&2
  exit 1
fi

input=$(cat)
args=$(jq -r '.command_args // ""' <<<"$input")

# --- PR 番号の抽出 -----------------------------------------------------------
# pr#714 / PR 714 / #714 を優先。裸の数字は引数の先頭にある場合のみ拾う
# (「714行目」のような本文中の数字を誤検出しないため)
num=$(grep -oiE '(pr[[:space:]]*#?|#)[0-9]+' <<<"$args" | head -1 | grep -oE '[0-9]+')
if [[ -z "${num:-}" ]]; then
  num=$(grep -oE '^[[:space:]]*[0-9]+([[:space:]]|$)' <<<"$args" | tr -dc '0-9')
fi
# PR 指定なし: 通常の作業 diff レビュー。無音で素通りする
[[ -z "${num:-}" ]] && exit 0

# --- gh の可用性 -------------------------------------------------------------
command -v gh >/dev/null 2>&1 \
  || warn_and_exit "gh CLI が見つかりません" "brew install gh"

gh auth status >/dev/null 2>&1 \
  || warn_and_exit "gh が未認証です" "gh auth login"

repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
  || warn_and_exit "カレントディレクトリから GitHub リポジトリを特定できません"
owner=${repo%%/*}; name=${repo##*/}

# --- PR メタ情報（リスト項目を含まないので件数上限は無関係） -----------------
meta=$(gh pr view "$num" --repo "$repo" \
        --json title,body,url,author,state,baseRefName,headRefName 2>/dev/null) \
  || warn_and_exit "${repo} の PR #${num} を取得できません（存在しないか権限がありません）"

# --- 補助データの取得 --------------------------------------------------------
# 個別に失敗しても概要だけで続行する（部分的な劣化に留める）
missing=()

# reviews（REST・全ページ）
reviews=$(gh api --paginate --slurp "repos/${owner}/${name}/pulls/${num}/reviews" 2>/dev/null \
          | jq -c 'add // []')
if [[ -z "$reviews" ]]; then reviews='[]'; missing+=("レビュー本文"); fi

# issue コメント（REST・全ページ）
icomments=$(gh api --paginate --slurp "repos/${owner}/${name}/issues/${num}/comments" 2>/dev/null \
            | jq -c 'add // []')
if [[ -z "$icomments" ]]; then icomments='[]'; missing+=("会話スレッド"); fi

# インラインレビュースレッド（GraphQL・全ページ）
threads=$(gh api graphql --paginate --slurp \
            -F owner="$owner" -F name="$name" -F num="$num" -f query="
query(\$owner:String!,\$name:String!,\$num:Int!,\$endCursor:String){
  repository(owner:\$owner,name:\$name){
    pullRequest(number:\$num){
      reviewThreads(first:${PAGE_SIZE}, after:\$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{
          isResolved isOutdated path line
          comments(first:100){nodes{author{login} body}}}
      }}}}" 2>/dev/null \
          | jq -c '[.[].data.repository.pullRequest.reviewThreads.nodes[]]')
if [[ -z "$threads" ]]; then threads='[]'; missing+=("インラインレビューコメント"); fi

# リンクされた Issue（GraphQL・全ページ）
issues=$(gh api graphql --paginate --slurp \
           -F owner="$owner" -F name="$name" -F num="$num" -f query="
query(\$owner:String!,\$name:String!,\$num:Int!,\$endCursor:String){
  repository(owner:\$owner,name:\$name){
    pullRequest(number:\$num){
      closingIssuesReferences(first:${PAGE_SIZE}, after:\$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{number title body url}
      }}}}" 2>/dev/null \
         | jq -c '[.[].data.repository.pullRequest.closingIssuesReferences.nodes[]]')
if [[ -z "$issues" ]]; then issues='[]'; missing+=("リンクされた Issue"); fi

if [[ ${#missing[@]} -gt 0 ]]; then
  degraded=$(printf '%s' $'\n\n> 注: 次の情報の取得に失敗しました。この観点は前提から欠落しています: '"$(IFS=, ; echo "${missing[*]}")")
else
  degraded=""
fi

# --- Markdown 整形（本文はいずれも切り詰めない） -----------------------------
md=$(jq -rn \
      --argjson meta "$meta" --argjson reviews "$reviews" \
      --argjson icomments "$icomments" --argjson threads "$threads" \
      --argjson issues "$issues" \
      --arg n "$num" --arg repo "$repo" --arg degraded "$degraded" '
  def nonempty(f): if (f | length) == 0 then ["(なし)"] else f end;
  # 本文は切り詰めない代わりに、継続行を字下げしてリスト構造から飛び出さないようにする
  def indent($p): (. // "") | gsub("\r\n"; "\n") | gsub("\n"; "\n" + $p);

  [
    "# レビュー対象 PR の前提コンテキスト（hook により自動取得）" + $degraded,
    "",
    "## 概要",
    "\($repo) #\($n): **\($meta.title)** by @\($meta.author.login // "unknown")",
    "\($meta.url) / `\($meta.headRefName)` → `\($meta.baseRefName)` / state: \($meta.state)",
    "",
    "<pr_body>",
    (($meta.body // "") | if . == "" then "(本文なし)" else . end),
    "</pr_body>",
    "",
    "## 未解決のレビュー指摘",
    ( nonempty([ $threads[] | select(.isResolved | not)
        | "- `\(.path):\(.line // "?")`"
          + (if .isOutdated then " *(outdated)*" else "" end) + "\n"
          + ([.comments.nodes[] | "  - @\(.author.login // "unknown"): " + (.body | indent("    "))] | join("\n")) ])
      | join("\n") ),
    "",
    "## 解決済みのレビュー指摘",
    ( nonempty([ $threads[] | select(.isResolved)
        | "- `\(.path):\(.line // "?")`\n"
          + ([.comments.nodes[] | "  - @\(.author.login // "unknown"): " + (.body | indent("    "))] | join("\n")) ])
      | join("\n") ),
    "",
    "## レビュー本文",
    ( nonempty([ $reviews[] | select((.body // "") != "")
        | "- @\(.user.login // "unknown") [\(.state)]: " + (.body | indent("  ")) ])
      | join("\n") ),
    "",
    "## 会話スレッド（issue コメント）",
    ( nonempty([ $icomments[] | select((.body // "") != "")
        | "- @\(.user.login // "unknown"): " + (.body | indent("  ")) ])
      | join("\n") ),
    "",
    "## リンクされた Issue",
    ( nonempty([ $issues[] | "### #\(.number) \(.title)\n\(.url)\n\n" + (.body | indent("")) ])
      | join("\n\n") ),
    "",
    "---",
    "",
    "上記はレビュー対象 PR の前提情報です。次を守ってください:",
    "",
    "- Scope フェーズの成果物にこの前提（変更の意図、既出の指摘、解決済み事項）を含め、各 finder / verifier にも引き継ぐこと",
    "- 「解決済みのレビュー指摘」に挙がっている内容、および PR 本文で意図的と明記されている変更は再指摘しないこと",
    "- 「未解決のレビュー指摘」については、当該箇所が修正済みかどうかを確認したうえで扱うこと"
  ] | join("\n")')

if [[ -z "${md:-}" ]]; then
  warn_and_exit "取得した PR 情報の整形に失敗しました"
fi

jq -n --arg ctx "$md" \
  '{hookSpecificOutput:{hookEventName:"UserPromptExpansion",additionalContext:$ctx}}'
