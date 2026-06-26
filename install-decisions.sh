#!/usr/bin/env bash
# decisions(意思決定ログ)システム インストーラ — 別端末で実行するだけで再現する。
# 冪等: 何度実行しても settings.json に重複追加しない。
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR/bin" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/decisions"

# 既存プロジェクトディレクトリを projects/ 配下へ移行(冪等)
PROJ_DIR="$CLAUDE_DIR/decisions/projects"
mkdir -p "$PROJ_DIR"
for d in "$CLAUDE_DIR/decisions"/*/; do
    name=$(basename "$d")
    [ "$name" = "projects" ] && continue
    if ls "$d"*.jsonl 2>/dev/null | grep -q .; then
        mv "$d" "$PROJ_DIR/$name"
    fi
done

# ───────────────────────── bin/decisions ─────────────────────────
cat > "$CLAUDE_DIR/bin/decisions" <<'PYEOF'
#!/usr/bin/env python3
"""意思決定ログ横断ビューア。

使い方:
  decisions                      全プロジェクト・最新順で一覧(要約)
  decisions <keyword>            全フィールド横断grep(部分一致, 大小無視)
  decisions -p <project>         プロジェクト名で絞り込み(部分一致)
  decisions -s 2026-06-01        その日以降
  decisions -u 2026-06-30        その日以前
  decisions -t plan              種別で絞り込み(AskUserQuestion/ExitPlanMode/llm_supplement の部分一致)
  decisions -n 20                表示件数(既定: 全件)
  decisions -f                   plan等の本文を全文表示
  decisions --json               生JSONをそのまま出力(jq等へパイプ用)
複数オプションは AND。
"""
import sys, os, json, argparse, glob

ROOT = os.path.expanduser("~/.claude/decisions")
C = {"dim": "\033[2m", "b": "\033[1m", "cy": "\033[36m", "gr": "\033[32m",
     "ye": "\033[33m", "r": "\033[0m"} if sys.stdout.isatty() else dict.fromkeys(
     ["dim", "b", "cy", "gr", "ye", "r"], "")

def load():
    recs = []
    for fp in glob.glob(os.path.join(ROOT, "projects", "*", "*.jsonl")):
        with open(fp, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    recs.append(json.loads(ln))
                except Exception:
                    pass
    recs.sort(key=lambda r: r.get("ts", ""), reverse=True)
    return recs

def matches(r, a):
    if a.project and a.project.lower() not in r.get("project", "").lower():
        return False
    if a.type and a.type.lower() not in r.get("type", "").lower():
        return False
    day = r.get("ts", "")[:10]
    if a.since and day < a.since:
        return False
    if a.until and day > a.until:
        return False
    if a.keyword and a.keyword.lower() not in json.dumps(r, ensure_ascii=False).lower():
        return False
    return True

def show(r, full):
    ts = r.get("ts", "").replace("T", " ")[:16]
    proj = r.get("project", "?")
    typ = r.get("type", "?")
    print(f"{C['dim']}{ts}{C['r']}  {C['cy']}[{proj}]{C['r']}  {C['b']}{typ}{C['r']}")
    if typ == "AskUserQuestion":
        for d in r.get("decisions", []):
            q = d.get("question", "")
            ans = d.get("answer")
            print(f"  {C['ye']}Q{C['r']} {q}")
            print(f"     -> {C['gr']}{ans}{C['r']}")
    elif typ == "ExitPlanMode":
        plan = r.get("plan", "")
        print(f"  {C['gr']}{plan if full else r.get('summary','')}{C['r']}")
    elif typ == "llm_supplement":
        for it in r.get("items", []):
            print(f"  {C['gr']}- {it.get('decision','')}{C['r']}")
            if it.get("reason"):
                print(f"    {C['dim']}理由: {it['reason']}{C['r']}")
    else:
        print(f"  {r.get('summary','')}")
    why = r.get("why_user")
    if why:
        print(f"  {C['dim']}契機: {why[:120]}{C['r']}")
    print()

def main():
    p = argparse.ArgumentParser(add_help=True, description="意思決定ログ横断ビューア")
    p.add_argument("keyword", nargs="?", help="横断grepキーワード")
    p.add_argument("-p", "--project")
    p.add_argument("-s", "--since")
    p.add_argument("-u", "--until")
    p.add_argument("-t", "--type")
    p.add_argument("-n", "--num", type=int)
    p.add_argument("-f", "--full", action="store_true")
    p.add_argument("--json", action="store_true")
    a = p.parse_args()

    if not os.path.isdir(ROOT):
        print("意思決定ログはまだありません:", ROOT)
        return
    recs = [r for r in load() if matches(r, a)]
    if a.num:
        recs = recs[:a.num]
    if a.json:
        for r in recs:
            print(json.dumps(r, ensure_ascii=False))
        return
    if not recs:
        print("該当なし")
        return
    for r in recs:
        show(r, a.full)
    print(f"{C['dim']}{len(recs)} 件{C['r']}")

if __name__ == "__main__":
    main()
PYEOF
chmod +x "$CLAUDE_DIR/bin/decisions"

# ─────────────────────── hooks/record_decision.py ───────────────────────
cat > "$CLAUDE_DIR/hooks/record_decision.py" <<'PYEOF'
#!/usr/bin/env python3
"""明示的な意思決定(AskUserQuestion / ExitPlanMode)を経緯込みで追記保存する。
PostToolUse hook から stdin で hook payload(JSON) を受け取る。Claude 不介在・追加トークン0。
失敗しても会話を止めないため、例外は握りつぶして exit 0。
"""
import sys, os, json, datetime

def main():
    if os.environ.get("CLAUDE_NO_DECISION_HOOKS") == "1":
        return  # headless claude が踏んだ場合は記録しない
    raw = sys.stdin.read()
    try:
        ev = json.loads(raw)
    except Exception:
        return
    tool = ev.get("tool_name", "")
    if tool not in ("AskUserQuestion", "ExitPlanMode"):
        return

    cwd = ev.get("cwd") or os.getcwd()
    proj = os.path.basename(cwd.rstrip("/")) or "root"
    transcript = ev.get("transcript_path", "")
    tin = ev.get("tool_input", {}) or {}
    tout = ev.get("tool_response", {}) or {}

    # 直前のユーザー発言とアシスタント発言を transcript 末尾から拾う(なぜこの判断に至ったか)
    last_user, last_asst = "", ""
    if transcript and os.path.exists(transcript):
        try:
            with open(transcript, encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()[-80:]
            for ln in lines:
                try:
                    o = json.loads(ln)
                except Exception:
                    continue
                role = o.get("type")
                m = o.get("message", {}) or {}
                c = m.get("content")
                txt = ""
                if isinstance(c, str):
                    txt = c
                elif isinstance(c, list):
                    for p in c:
                        if isinstance(p, dict) and p.get("type") == "text":
                            txt += p.get("text", "")
                txt = txt.strip()
                if not txt or txt.startswith("<"):
                    continue
                if role == "user" and "tool_result" not in txt:
                    last_user = txt
                elif role == "assistant":
                    last_asst = txt
        except Exception:
            pass

    # 判断の中身を整形
    if tool == "AskUserQuestion":
        decisions = []
        qs = tin.get("questions", []) or []
        answers = (tout.get("answers") if isinstance(tout, dict) else None) or {}
        for q in qs:
            qtext = q.get("question", "")
            opts = [o.get("label", "") for o in q.get("options", [])]
            decisions.append({
                "question": qtext,
                "options": opts,
                "answer": answers.get(qtext) if isinstance(answers, dict) else None,
            })
        payload = {"kind": "user_choice", "decisions": decisions}
        summary = "; ".join(
            f"{d['question'][:40]} => {d['answer']}" for d in decisions if d.get("answer")
        )
    else:  # ExitPlanMode
        plan = tin.get("plan", "")
        payload = {"kind": "plan_approved", "plan": plan}
        summary = "計画承認: " + " ".join(plan.split())[:80]

    rec = {
        "ts": datetime.datetime.now().isoformat(timespec="seconds"),
        "project": proj,
        "cwd": cwd,
        "type": tool,
        "summary": summary,
        "why_user": last_user[:300],
        "why_assistant": last_asst[:300],
        **payload,
    }

    day = datetime.date.today().isoformat()
    outdir = os.path.expanduser(f"~/.claude/decisions/projects/{proj}")
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, f"{day}.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")

if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
PYEOF

# ───────────────────── hooks/decision_supplement.py ─────────────────────
cat > "$CLAUDE_DIR/hooks/decision_supplement.py" <<'PYEOF'
#!/usr/bin/env python3
"""ハイブリッドのB部分: セッション終了時に1回だけ、明示判断ログに残らない
"暗黙の方針判断/方針転換" を haiku(headless) で抽出して補完追記する。
コスト最小化: ユーザー発言のみを渡す / haiku 固定 / 再帰ガードあり / 失敗は黙殺。
"""
import sys, os, json, subprocess, datetime

GUARD = "CLAUDE_NO_DECISION_HOOKS"

def main():
    if os.environ.get(GUARD) == "1":
        return  # headless claude が再びこの hook を踏むのを防ぐ
    raw = sys.stdin.read()
    try:
        ev = json.loads(raw)
    except Exception:
        return
    cwd = ev.get("cwd") or os.getcwd()
    proj = os.path.basename(cwd.rstrip("/")) or "root"
    transcript = ev.get("transcript_path", "")
    if not transcript or not os.path.exists(transcript):
        return

    # ユーザー発言だけ抽出(最大40件)
    users = []
    with open(transcript, encoding="utf-8", errors="replace") as fh:
        for ln in fh:
            try:
                o = json.loads(ln)
            except Exception:
                continue
            if o.get("type") != "user":
                continue
            c = (o.get("message", {}) or {}).get("content")
            txt = ""
            if isinstance(c, str):
                txt = c
            elif isinstance(c, list):
                for p in c:
                    if isinstance(p, dict) and p.get("type") == "text":
                        txt += p.get("text", "")
            txt = txt.strip()
            if txt and not txt.startswith("<") and "tool_result" not in txt:
                users.append(txt[:300])
    if len(users) < 2:
        return  # 短いセッションは補完不要

    convo = "\n".join(f"- {u}" for u in users[-40:])
    prompt = (
        "以下はユーザーの発言列(時系列)。会話の中で下された重要な"
        "『方針判断・方針転換・採用/不採用の決定』だけを抽出せよ。"
        "雑談や単純な作業指示は除く。各項目 {decision, reason} の JSON 配列のみを出力。"
        "該当なしは [] のみ。日本語。\n\n発言:\n" + convo
    )

    env = dict(os.environ)
    env[GUARD] = "1"
    try:
        out = subprocess.run(
            ["claude", "-p", prompt, "--model", "claude-haiku-4-5-20251001"],
            capture_output=True, text=True, timeout=120, env=env,
        ).stdout.strip()
    except Exception:
        return

    # JSON 配列部分を取り出す
    s, e = out.find("["), out.rfind("]")
    if s == -1 or e == -1 or e < s:
        return
    try:
        items = json.loads(out[s:e + 1])
    except Exception:
        return
    if not isinstance(items, list) or not items:
        return

    rec = {
        "ts": datetime.datetime.now().isoformat(timespec="seconds"),
        "project": proj,
        "cwd": cwd,
        "type": "llm_supplement",
        "items": items,
    }
    day = datetime.date.today().isoformat()
    outdir = os.path.expanduser(f"~/.claude/decisions/projects/{proj}")
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, f"{day}.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")

if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
PYEOF

# ─────────────── hooks/auto_push_decisions.sh ───────────────────────
cat > "$CLAUDE_DIR/hooks/auto_push_decisions.sh" <<'SHEOF'
#!/usr/bin/env bash
# SessionEnd hook: decisions ログを自動 commit & push する

set -euo pipefail

DECISIONS_DIR="$HOME/.claude/decisions"
cd "$DECISIONS_DIR"

# 変更がなければ終了
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    exit 0
fi

DATE=$(date +%Y-%m-%d)
git add projects/
git diff --cached --quiet && exit 0  # add 後も差分なければ終了

git commit -m "chore: auto-save decisions log ${DATE}"
git push origin main
SHEOF
chmod +x "$CLAUDE_DIR/hooks/auto_push_decisions.sh"

# ─────────────── settings.json に hooks を冪等マージ ───────────────
SETTINGS="$CLAUDE_DIR/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

python3 - "$SETTINGS" <<'PYEOF'
import json, sys
fp = sys.argv[1]
try:
    d = json.load(open(fp, encoding="utf-8"))
except Exception:
    d = {}
hooks = d.setdefault("hooks", {})

def has(events, needle):
    for grp in events:
        for h in grp.get("hooks", []):
            if needle in h.get("command", ""):
                return True
    return False

# PostToolUse: AskUserQuestion|ExitPlanMode -> record_decision.py
ptu = hooks.setdefault("PostToolUse", [])
if not has(ptu, "record_decision.py"):
    ptu.append({
        "matcher": "AskUserQuestion|ExitPlanMode",
        "hooks": [{"type": "command",
                   "command": 'python3 "$HOME/.claude/hooks/record_decision.py"'}],
    })

# SessionEnd -> decision_supplement.py (バックグラウンド)
se = hooks.setdefault("SessionEnd", [])
if not has(se, "decision_supplement.py"):
    se.append({
        "hooks": [{"type": "command",
                   "command": 'd=$(cat); printf \'%s\' "$d" | '
                              'python3 "$HOME/.claude/hooks/decision_supplement.py" '
                              '>/dev/null 2>&1 &'}],
    })

# SessionEnd -> auto_push_decisions.sh (バックグラウンド)
if not has(se, "auto_push_decisions.sh"):
    # 既存グループに追加、なければ新規グループ
    if se:
        se[0]["hooks"].append({
            "type": "command",
            "command": 'bash "$HOME/.claude/hooks/auto_push_decisions.sh" >/dev/null 2>&1 &',
        })
    else:
        se.append({
            "hooks": [{"type": "command",
                       "command": 'bash "$HOME/.claude/hooks/auto_push_decisions.sh" >/dev/null 2>&1 &'}],
        })

json.dump(d, open(fp, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("settings.json updated:", fp)
PYEOF

# ─────────────── PATH 確認 ───────────────
case ":$PATH:" in
  *":$CLAUDE_DIR/bin:"*) ;;
  *) echo "ヒント: PATH に未登録。次を shell rc に追加 → export PATH=\"\$HOME/.claude/bin:\$PATH\"" ;;
esac

echo "✅ decisions システム導入完了。新しい Claude Code セッションから記録が始まります。"
echo "   確認: decisions   /   無効化: 環境変数 CLAUDE_NO_DECISION_HOOKS=1"
