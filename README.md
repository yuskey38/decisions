# Claude Code 意思決定ログシステム

Claude Code のセッション中に行われた意思決定を自動記録・閲覧するシステム。

## セットアップ

```bash
bash install-decisions.sh
```

`~/.claude/bin` を PATH に追加していない場合は案内が表示される。

```bash
export PATH="$HOME/.claude/bin:$PATH"  # ~/.zshrc 等に追記
```

## ログビューア (`decisions` コマンド)

```bash
decisions                        # 全プロジェクト・最新順で一覧
decisions <keyword>              # 全フィールド横断grep
decisions -p <project>           # プロジェクト名で絞り込み
decisions -s 2026-06-01          # その日以降
decisions -t AskUserQuestion     # 種別で絞り込み
decisions -f                     # plan等の本文を全文表示
decisions --json | jq .          # 生JSONをパイプ
```

## アーキテクチャ

installer が配置する3つのコンポーネントが連携している。

| コンポーネント | 場所 | 役割 |
|---|---|---|
| `decisions` CLI | `~/.claude/bin/decisions` | ログの横断検索・閲覧 |
| `record_decision.py` | `~/.claude/hooks/record_decision.py` | **PostToolUse** hook。`AskUserQuestion` / `ExitPlanMode` 発火時に即時記録 |
| `decision_supplement.py` | `~/.claude/hooks/decision_supplement.py` | **SessionEnd** hook。セッション終了時に Claude Haiku で暗黙の方針判断を補完追記 |

### ログの保存先

```
~/.claude/decisions/<project>/<YYYY-MM-DD>.jsonl
```

### ログレコードの型

```
type: "AskUserQuestion"   -> decisions[] に質問・選択肢・回答
type: "ExitPlanMode"      -> plan（全文）+ summary
type: "llm_supplement"    -> items[]{decision, reason}（Haiku 抽出）
```

共通フィールド: `ts`, `project`, `cwd`, `summary`, `why_user`, `why_assistant`

## 無効化

```bash
CLAUDE_NO_DECISION_HOOKS=1 claude ...   # 一時的に記録を止める
```
