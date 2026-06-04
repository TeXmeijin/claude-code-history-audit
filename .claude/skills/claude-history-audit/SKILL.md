---
name: claude-history-audit
description: Claude Code の履歴 JSONL に残った secret(token/APIキー/DB認証情報等) を監査・redact する。モード分けされ、ユーザーの指示に従って動く。トリガー：「履歴を監査して」「Claude履歴のsecret確認」「履歴を掃除して」「redactして」「履歴の漏れチェック」「Stop hook入れたい」「履歴をsweepして」。
---

# Claude Code History Audit

このリポジトリの 2 本のスクリプトを、モード分けして安全に運用するための skill。

- `scripts/audit-claude-history-for-project.sh` … read-only。secret 種別ごとに件数を出す
- `scripts/redact-claude-history-secrets.sh` … placeholder 置換 or 行削除（ファイルを書き換える）

検出対象は両スクリプト共通（GitHub/OpenAI/Anthropic/Stripe/AWS access key id・secret access key/Google/Slack/JWT/DB URL cred/PEM）。

## 鉄則（安全境界）

1. **ユーザーの語からモードを判定し、自分で「適用」へ昇格しない。** 「掃除して」のような曖昧指示は 監査→プレビュー まで進め、**適用の直前で必ず止まって確認**する。
2. **破壊的操作（適用 / `--mode drop-line` / Stop hook 設置）は毎回ユーザーの明示承認が要る。** 承認前に「対象 root・対象ファイル数・件数・mode」を提示する。
3. **生 secret を会話に出さない。** 監査 / プレビュー の出力は placeholder 済みなのでそのまま見せてよい。
4. `--all`（全履歴対象）は明示要求があるときだけ。既定は現在のプロジェクト。

## モード

モード名は日本語を主にする（日本語ユーザーが会話で呼びやすいように）。ユーザーは「監査して」「プレビュー見せて」「適用して」「一掃して」「hook入れて」のように指示する。

### 監査（audit・既定・read-only）
現在のプロジェクト履歴を scan して件数を要約。まず必ずここから。
```bash
# カレントプロジェクト（cd して引数なしが最短）
scripts/audit-claude-history-for-project.sh
# 件数だけ
scripts/audit-claude-history-for-project.sh --summary-only
# 特定プロジェクト（~/.claude/projects/ の符号化dir名への部分一致regex。リポのフォルダ名でOK）
scripts/audit-claude-history-for-project.sh --project-name 'my-repo'
```
候補プロジェクト名は `ls ~/.claude/projects/` で確認できる。

### プレビュー（preview・redact --dry-run・ファイル不変）
置換結果をプレビューする。適用の前段として使う。
```bash
scripts/redact-claude-history-secrets.sh --dry-run
scripts/redact-claude-history-secrets.sh --project-name 'my-repo' --dry-run
```

### 適用（apply・破壊的・要明示承認）
実際に履歴を書き換える。**必ず直前にプレビューを見せ、対象スコープを確認してから。**
```bash
scripts/redact-claude-history-secrets.sh --apply                 # placeholder 置換
scripts/redact-claude-history-secrets.sh --apply --mode drop-line # 該当行ごと削除
```
ファイルごとに一時ファイルへ書いて `rename(2)` で置換（permission bits 引き継ぎ）。JSONL 構造は維持されるので過去会話の閲覧/resume を壊しにくい。

### 一掃点検（sweep・定期点検）
hook で取りこぼした古い履歴を週次などで全履歴 dry-run する。
```bash
scripts/redact-claude-history-secrets.sh --all --since-days 7 --dry-run
# 点検して問題なければ apply（要承認）
scripts/redact-claude-history-secrets.sh --all --since-days 7 --apply
```

### hook設置（setup-hook・Stop hook 設置・要承認）
セッション終了ごとに現セッションを自動 redact する。`.claude/settings.json` の Stop に追加:
```json
{ "type": "command",
  "command": "scripts/redact-claude-history-secrets.sh --from-hook --apply --quiet",
  "timeout": 10 }
```
`--from-hook` は stdin の hook JSON から `cwd` と `transcript_path` を拾う。設置前に必ず同じ root 指定で dry-run を通す。

## 履歴 root が ~/.claude 以外のとき
`CLAUDE_CONFIG_DIR` / `CLAUDE_HISTORY_ROOTS`（`:`区切り）/ `--root` / `--config-dir` で指定。両スクリプト共通。
