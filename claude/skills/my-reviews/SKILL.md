---
name: my-reviews
description: GitHubで自分にレビュー依頼されているオープンなPRを一覧表示する。「レビュー依頼」「レビュー一覧」「自分に来ているPR」などと言われたら使う。
disable-model-invocation: false
---

`gh` CLIを使って、現在のユーザーにレビュー依頼されているオープンなPull Requestを取得し、一覧表示する。

## 手順

以下のコマンドを実行する。

```bash
gh search prs --review-requested=@me --state=open \
  --json number,title,repository,author,url,updatedAt --limit 100
```

## 出力形式

取得結果を以下の形式で表にまとめ、日本語で報告する。

- 列: PR番号（URLへのリンク）、リポジトリ、タイトル、作成者、最終更新日
- 更新日時の新しい順に並べる
- 該当するPRが0件の場合は「レビュー依頼されているPRはありません」と伝える
