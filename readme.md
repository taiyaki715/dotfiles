## claude

Claude Code のユーザー設定。

```
./claude/settings.json         -> ~/.claude/settings.json
./claude/statusline-command.sh -> ~/.claude/statusline-command.sh
./claude/hooks                 -> ~/.claude/hooks
./claude/skills                -> ~/.claude/skills
```

リンクは `./claude/setup.sh` で作成する（冪等・再実行可能）。

`~/.claude` には会話ログ（`history.jsonl`, `projects/`, `sessions/`）やアプリのキャッシュが
同居しているため、ディレクトリ全体はリンクしない。

`settings.json` は Claude Code 自身が書き換えるファイル（モデル変更、プラグインの有効化など）。
書き換え時にシンボリックリンクが実ファイルに置き換えられると、git 管理から静かに外れる。
`ls -l ~/.claude/settings.json` がリンクでなくなっていたら `./claude/setup.sh` を再実行する。

## ghostty

./ghostty -> ~/.config/ghostty

## starship

starship.toml -> ~/.config/starship.toml

## zsh

.zshrc -> ~/.zshrc
