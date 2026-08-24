#!/usr/bin/env python3
"""mqvpn ダッシュボード (サーバー別版) を生成する。

入力は上流 mqvpn-prometheus-exporter の dashboards/mqvpn-grafana.json
やること:
  1. ${DS_PROMETHEUS} プレースホルダを datasource uid (prometheus) に置換
  2. instance テンプレ変数を追加 (候補 = label_values(mqvpn_build_info,
     instance)、初期値 = compose の全 mqvpn-server-* を選択状態。「All」
     アイテムは持たない)
  3. 全 PROMQL に {instance=~"$instance"} を注入
     (既存の {user=...} には追記、素のメトリック名には後付け。
      「(」は関数名 (rate 等) に誤マッチするため除外。
      直後が `)` の素メトリック (topk(5, metric) 等) も対象)

Usage:
  python3 mqvpn-dashboard-per-server.py BASE_JSON OUT_JSON [COMPOSE_YAML]
  (COMPOSE_YAML: 既定選択とするサーバー一覧の取得元。無くても動くが、
   初期選択が空になる)
"""

import json
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))

# 1) datasource input プレースホルダ → プロビジョニング uid
text = json.dumps(d).replace("${DS_PROMETHEUS}", "prometheus")
d = json.loads(text)

# 0) 既定の表示範囲 / リフレッシュ: Last 5 minutes, auto
d["time"] = {"from": "now-5m", "to": "now"}
d["refresh"] = "auto"

# 2) uid / title は上流のまま (mqvpn-exporter-v1 / mqvpn) を使う。

# 3) instance テンプレ変数 (Server 切替)。
# 候補は label_values で実行時に自動更新されるが、Grafana の multi 変数の初期
# 状態は固定リストしか持てない。「All」アイテムは設けず、焼き込み時点の
# 全サーバーを既定選択にする (増設時も prometheus targets と同じく再ビルドで
# この初期リストが更新されるため、開いた瞬間に全サーバー表示になる)
instances = []
if len(sys.argv) >= 4:
    compose_text = open(sys.argv[3]).read()
    instances = [
        f"{n}:9091"
        for n in re.findall(r"^\s+(mqvpn-server-[0-9]+):", compose_text, re.M)
    ]
d["templating"]["list"].append(
    {
        "name": "instance",
        "label": "Server",
        "type": "query",
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "query": {
            "query": "label_values(mqvpn_build_info, instance)",
            "refId": "StandardVariableQuery",
        },
        "refresh": 2,
        "multi": True,
        "current": {"text": instances, "value": instances, "selected": True},
        "sort": 1,
        "hide": 0,
        "regex": "",
    }
)

# 4) PROMQL への instance 注入。
# メトリック名 (mqvpn_*) を個別に走査し、既存の {..} ラベル集合には追記、
# 素メトリックには名前の直後に付与する。全メトリックを対象にするため
# 「rate(A) / rate(B)」のような複数メトリック式でも漏れない
INST = 'instance=~"$instance"'


def transform(expr):
    out = []
    last = 0
    for m in re.finditer(r"mqvpn_[A-Za-z0-9_]+", expr):
        end = m.end()
        out.append(expr[last:end])
        nxt = expr[end] if end < len(expr) else ""
        if nxt == "{":
            close = expr.find("}", end)
            if close == -1:  # 壊れた式 (`{` が閉じない): 素として処理
                out.append("{" + INST + "}")
                last = end
                continue
            blk = expr[end : close + 1]
            out.append(blk if "instance=" in blk else blk[:-1] + "," + INST + "}")
            last = close + 1
        else:
            out.append("{" + INST + "}")
            last = end
    out.append(expr[last:])
    return "".join(out)


def walk(o):
    if isinstance(o, dict):
        if "expr" in o and isinstance(o["expr"], str):
            o["expr"] = transform(o["expr"])
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)


walk(d)

# 5) セルフチェック: 全 PROMQL の各メトリックに instance フィルタが付いている
# こと。「mqvpn_* の数 <= instance= の数」を要求する。mqvpn_ は関数名に
# 現れないため確実に判定できる (変換の漏れはここでビルド失敗にできる)
missing = []
filters = 0


def count_metrics(expr):
    return len(re.findall(r"mqvpn_[A-Za-z0-9_]+", expr))


def count_filters(expr):
    return len(re.findall(r"instance=", expr))


def check(o):
    global filters
    if isinstance(o, dict):
        if "expr" in o and isinstance(o["expr"], str):
            # この検査は「mqvpn_* メトリックごとに instance= フィルタが 1 個以上」
            # を要求する。mqvpn_ は関数名に現れないため確実に判定できる
            # (プレースホルダ式 / 変数定義は "expr" キーを持たないので対象外)
            n_metrics, n_filter = count_metrics(o["expr"]), count_filters(o["expr"])
            filters += n_filter
            if n_metrics > n_filter:
                missing.append(
                    f"{n_metrics} メトリック / {n_filter} フィルタ: {o['expr']}"
                )
        for v in o.values():
            check(v)
    elif isinstance(o, list):
        for v in o:
            check(v)


check(d)
if missing:
    sys.exit(
        "ERROR: instance フィルタが漏れた expr がある (上流が複数メトリック式か変換バグ):\n"
        + "\n".join(missing)
    )

json.dump(d, open(dst, "w"), indent=2)
print(f"generated: {dst} (uid={d['uid']}, instance フィルタ {filters} 箇所)")

