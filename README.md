# Claude Code History Audit

Claude CodeのprojectごとのJSONL履歴に対して、token・APIキー・DB credentialなどのsecretらしき文字列を検出・redactするためのbashスクリプト集です。

## なぜ作ったか — 出口対策の一環として

このツールは完璧な対策ではなく、問題が起きることそのものを防ぐためのものではありません。普段からトークンをハードコードせずsecret managerで管理していても、Claude Codeを使っている過程で履歴ファイルにトークンが残ってしまうことは多少なりとも起きえます。出口対策の一環として、履歴側を後から掃除しておくためのスクリプトです。

履歴に残る経路はいくつかあります。日頃からトークンをハードコードしていない人でも、AIが `gh` などのコマンドを実行すると、ghコマンドからトークンが引っ張られてきて、その出力がそのまま履歴に残ります。`Read` ツールで鍵が書いてあるファイルを開いた場合も同じです。AIにshell実行を任せる以上こうした経路を完全に塞ぐのは難しく、普段鍵系をすべてsecret managerで管理している人でも履歴は要注意です。

履歴ファイルがディレクトリに長く置かれているほどリスクは積み上がります。Claude Codeの履歴保持期間を `cleanupPeriodDays: 9999` のように長くするtipsがweb上で見受けられますが、そう設定している場合は、履歴ファイルのディレクトリにずっと秘密鍵が残っていることになり、端末やバックアップを攻撃者に盗まれた時にそこから抜かれる可能性がそのぶん残り続けます。

セッションが終わる度などにこまめにリダクトしておけば、何かあった時に履歴から抜かれる秘密の量を著しく減らせます。`--mode redact` はJSONL構造を維持してプレースホルダ置換するので、過去会話の閲覧やresumeを壊しにくい形で運用できます。

## スクリプト

含まれるのは2本のスクリプトだけです。

| Script | 用途 |
| --- | --- |
| `scripts/audit-claude-history-for-project.sh` | 履歴JSONLをscanしてsecret種別ごとの件数を出す（read-only） |
| `scripts/redact-claude-history-secrets.sh` | 検出した文字列を `<GITHUB_TOKEN>` などのplaceholderへ置換、または該当行を削除する |

ファイルを書き換えるのは `redact` 側だけです。`audit` 側は読み取りのみです。

## Agent Skill（任意）

会話から呼べる Claude Code skill を同梱しています（[.claude/skills/claude-history-audit/SKILL.md](.claude/skills/claude-history-audit/SKILL.md)）。このリポジトリを clone した状態で「履歴を監査して」「履歴を掃除して」などと話しかけると発動します。**監査 / プレビュー / 適用 / 一掃点検 / hook設置** のモードに分かれ、破壊的な「適用」はユーザーの明示承認を得てから実行する設計です。

## 検出対象

`audit` と `redact` で共通の検出セットです（同じ正規表現を使います）。文脈に依存せずパターンで判定するので、ログ・コマンド出力・toolリクエスト・toolレスポンスのいずれに含まれていてもhitします。`audit` 側はこれに加えて、pipelock/permission拒否などの運用マーカーの件数も表示します（secretではありません）。

- GitHub classic PAT (`ghp_…`, `gho_…`, `ghu_…`, `ghs_…`, `ghr_…`)
- GitHub fine-grained PAT (`github_pat_…`)
- OpenAI keys (`sk-…`, `sk-proj-…`)
- Anthropic keys (`sk-ant-api03-…`)
- Stripe keys (`sk_live_…`, `rk_live_…`, `sk_test_…`)
- AWS access key IDs (`AKIA…`, `ASIA…`)
- AWS secret access keys — `aws_secret_access_key` 等のラベルが付いた40文字 base64-ish値、または `AKIA`/`ASIA` と同一行に並ぶ40文字 base64-ish 値（SHA1 hex は除外）
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

`--project-name` の値は、`~/.claude/projects/` 直下の**ディレクトリ名に対する正規表現（部分一致）**です。各ディレクトリ名はプロジェクトの絶対パスを符号化したもの（`/` などが `-` に置換される）なので、普段は**リポジトリのフォルダ名をそのまま渡せば**当たります。候補は `ls ~/.claude/projects/` で確認できます。`--project-name` を渡すと、stdoutに「どの `projects/*` ディレクトリにヒットしたか」が表示されるので、`--apply` 前に対象範囲を確認できます。

なお、対象プロジェクトに `cd` して引数なしで実行すれば、`--target`（デフォルト `pwd`）が効くので project-name を指定しなくても今いるプロジェクトの履歴を対象にできます（最短の試し方）。

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

定期 sweep（直近n日の全履歴をdry-runで点検）:

```bash
scripts/redact-claude-history-secrets.sh --dry-run --all --since-days 7
scripts/redact-claude-history-secrets.sh --apply   --all --since-days 7
```

Stop hookはセッション直後のlocalな掃除なので、 hookで取りこぼした古い履歴を週次などで sweep する用途を想定しています。

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
