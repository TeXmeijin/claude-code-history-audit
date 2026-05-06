# Claude Code History Audit

Claude CodeのprojectごとのJSONL履歴に対して、token・APIキー・DB credentialなどのsecretらしき文字列を検出・redactするためのbashスクリプト集です。

含まれるのは2本のスクリプトだけです。

| Script | 用途 |
| --- | --- |
| `scripts/audit-claude-history-for-project.sh` | 履歴JSONLをscanしてsecret種別ごとの件数を出す（read-only） |
| `scripts/redact-claude-history-secrets.sh` | 検出した文字列を `<GITHUB_TOKEN>` などのplaceholderへ置換、または該当行を削除する |

ファイルを書き換えるのは `redact` 側だけです。`audit` 側は読み取りのみです。

## 検出対象

両スクリプトで共通する正規表現です。文脈に依存せずパターンで判定するので、ログ・コマンド出力・toolリクエスト・toolレスポンスのいずれに含まれていてもhitします。

- GitHub classic PAT (`ghp_…`, `gho_…`, `ghu_…`, `ghs_…`, `ghr_…`)
- GitHub fine-grained PAT (`github_pat_…`)
- OpenAI keys (`sk-…`, `sk-proj-…`)
- Anthropic keys (`sk-ant-api03-…`)
- Stripe keys (`sk_live_…`, `rk_live_…`, `sk_test_…`)
- AWS access key IDs (`AKIA…`, `ASIA…`)
- Google API keys (`AIza…`)
- Slack tokens (`xoxb-…` 系)
- JWT (`eyJ…` 3-part)
- DB URLの埋め込み credential (`postgres://user:pass@…`, `mysql://…`, `mongodb://…`, `redis://…`)
- PEM private key blocks

正規表現の細部は各スクリプト内を参照してください。

## 履歴のscan対象

デフォルトは次の順でroot解決します。

1. `--config-dir <dir>` が渡されていればそれだけ
2. それ以外は環境変数 `CLAUDE_CONFIG_DIR`
3. それも無ければ `~/.claude`

追加で複数rootを見たい場合は `CLAUDE_HISTORY_ROOTS`（`:` 区切り）または `--root <dir>` を使います。各root配下の `projects/*` と `transcripts/*` が `.jsonl` の探索範囲です。

絞り込みオプション:

| オプション | 動作 |
| --- | --- |
| `--target <path>` | そのパスを参照しているJSONLだけに限定（デフォルト: `pwd`） |
| `--project-name <regex>` | `projects/*` のディレクトリ名を正規表現で絞る |
| `--all` | 配下のJSONLを全て対象 |
| `--latest <n>` | 更新日時が新しいものからn件 |
| `--since-days <n>` | 直近n日以内に更新されたものだけ |
| `--summary-only` | 詳細行を出さずsecret種別ごとの合計だけ出力 |

`--project-name` を渡すと、stdoutに「どの `projects/*` ディレクトリにヒットしたか」が表示されます。`--apply` 前に対象範囲を確認できます。

## Audit

```bash
npm run history:audit
```

カレントディレクトリのproject pathを参照しているJSONLを対象に、secret種別ごとの件数とredact済みの該当行（最大40行/file）を出力します。

履歴が多いprojectでは、まず軽量モードで全体感を見ます。

```bash
npm run history:audit:fast -- --project-name 'my-project'
npm run history:audit:summary -- --project-name 'my-project'
```

直接スクリプトを叩く例:

```bash
scripts/audit-claude-history-for-project.sh --project-name 'my-project'
scripts/audit-claude-history-for-project.sh --project-name 'my-project' --since-days 7 --summary-only
scripts/audit-claude-history-for-project.sh --config-dir "$HOME/path-to-claude-config"
```

Auditの出力ではproject pathや`$HOME`をredactした表示にします。stdoutをコピペしてもfile path自体が漏れにくいようにする、ぐらいの軽い意味です。

## Redact

`Read` toolで既存ファイルを読んだ瞬間にsecret文字列が履歴JSONLに残るのは、PreToolUse hookだけでは防ぎきれない場面があります。`redact` は履歴側を後から書き換える運用です。

Dry Run（デフォルト）:

```bash
npm run history:redact:dry-run
```

実際に置換:

```bash
npm run history:redact:apply
```

スクリプト直叩きの例:

```bash
scripts/redact-claude-history-secrets.sh --project-name 'my-project' --dry-run
scripts/redact-claude-history-secrets.sh --project-name 'my-project' --apply
scripts/redact-claude-history-secrets.sh --project-name 'my-project' --latest 20 --dry-run
scripts/redact-claude-history-secrets.sh --apply --mode drop-line
```

| `--mode` | 動作 |
| --- | --- |
| `redact`（デフォルト） | 検出文字列だけを `<GITHUB_TOKEN>` などのplaceholderに置換。JSONLの行構造は維持 |
| `drop-line` | 検出にhitしたJSONL行を丸ごと削除 |

`--apply` は、ファイルごとに同じディレクトリに `.redact-history.XXXXXX` の一時ファイルを書いてから `rename(2)` で置き換えます。元ファイルのpermission bitsは引き継ぎます。

## Stop hookに入れる場合

project localの `.claude/settings.local.json` 例:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "scripts/redact-claude-history-secrets.sh --from-hook --apply --quiet",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

`--from-hook` はstdinからClaude Code hookのJSONを読み、`cwd` と `transcript_path` を拾います。`jq` が無ければJSONパースをskipして通常モードに落ちます。

Stop hookに入れる前に、必ず同じroot指定でDry Runを通してください。

## 履歴rootが `~/.claude` 以外にある場合

```bash
CLAUDE_CONFIG_DIR="$HOME/path-to-claude-config" scripts/audit-claude-history-for-project.sh
CLAUDE_HISTORY_ROOTS="$HOME/path-to-other-claude-dir" scripts/audit-claude-history-for-project.sh
scripts/audit-claude-history-for-project.sh --config-dir "$HOME/path-to-claude-config"
```

`redact` 側も同じoptions/環境変数を受け付けます。

## 依存

- bash
- perl 5（macOS / 主要なLinux distroにbundleされているもので動く想定）
- ripgrep (`rg`) — `--target` 指定時のJSONL候補絞り込みに使用
- jq — `--from-hook` 利用時のみ必須

## 参考

- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
