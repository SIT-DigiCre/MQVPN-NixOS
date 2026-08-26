# mqvpn WLB フローピン集中崩壊 (本番: 3x Starlink の下りが 1 本に固着)

> 更新: 2026-08-27
> 対象ビルド: mqvpn v0.16.1 (router: mqvpn-0.16.1, xquic 9ed9642e65b), cc=bbr, scheduler=wlb,
> reinjection=deadline (採用指針 chiken/mqvpn-single-thread-cpu-bottleneck.md の "off" と不一致 — 別件),
> hybrid 無効, manage_routes=false。本番実測 + ラボ再来 (xquic ソース読解込み)。
> ソース: github:mp0rta/mqvpn @v0.16.1, third_party/xquic/src/transport/scheduler/xqc_scheduler_wlb.c

## 現象

- ルーター: NixOS, enp10s0=LAN (172.16.0.1/12), WAN 3 本 = Starlink×3
  (enp1s0f0=192.168.4.204/gw .4.1, enp1s0f2=.1.146/gw .1.1, enp1s0f3=.1.175/gw .1.1)、
  モバイル 3 + eduroam 1 は NO-CARRIER (閉)。
- サーバー: Ryzen 9 7900 2vCPU (Ubuntu 26.04 + docker host-net mqvpn-server-0/1,
  UDP 443/444, POSTROUTING 192.168.0.0/24・192.168.1.0/24 → ens3 MASQUERADE)。
- ECMP: default nhid 2000 = mqvpn0/mqvpn1 (L4 hash_policy=1), サーバー IP は 3 WAN の
  multipath ピン (/32) で接続 (outer がトンネルへループしないため)。
- **speedtest が「微妙な数値」: 下り ~450 Mbps 頭打ち (最良 1 本の Starlink 相当)、
  上りも ~25 Mbps 前後。回線・トンネル・サーバーはボトルネックでない。**

## 計測方法・結果 (本番, ルーター journalctl STATUS 5s サンプル + DC 側 telemetry)

| テスト | 合計 DL | パス別 rx (同時刻ウィンドウ) |
|---|---|---|
| ユーザー speedtest 1 発 (21:29) | ~458 Mbps | f0 100% (mqvpn-1)、f2/f3 ≈0 |
| speedtest-go 2 並列 (21:36) | ~194 Mbps | f0 100% (両 conn)、f2/f3 ≈0 |
| speedtest-go 4 並列 (21:40) | クライアント表示 合計 ~395 Mbps / カウンタ ~1.1 Gbps | f0 ~500MB + f2 ~23MB + f3 ~22MB (溢れ発生) |
| speedtest-go 2 並列 (21:45) | ~449 Mbps | f0 100%、f2/f3 ≈0 |

- 4 並列時のみ f2/f3 に一瞬溢れ (≒5%)。溢れ時 jitter 崩壊 (135–446ms, max 1444ms)。
- dgram_lost ~0.1% と小、パス障害なし。f0 単体実力 ~458 Mbps を確認 (回線劣化ではない)。
- サーバー checkpoint: srtt 22-95ms/min_rtt 15ms、サーバー CPU は余裕。

## 原因 (実装読解: xquic xqc_scheduler_wlb.c @ 9ed9642e65b)

モデル (関数: `wlb_compute_weight` L529, `late_estimate_dgram` L443, `wlb_pick_pin_path` L736, `wlb_start_round` L697):

1. **TCP フローは po_flow_hash → 1 パスにピン** (flow table, 60s idle expiry)。
   UDP/ICMP は UNPINNED → パケット単位 WRR で分散 (実トラフィックが TCP なので崩壊対象外)。
2. **ピン先 = deficit 最大パス** (`wlb_pick_pin_path`)。deficit は各 WRR ラウンドで
   `quantum = weight / min_weight` だけ加算 (`wlb_start_round`)。
3. **weight = `wlb_compute_weight` → `late_estimate_dgram` の N×1000**。N は「時間窓 T で
   配送期待パケット数」で、実質 **cwnd(pkts) そのもの**に比例 (LATE は 1 ラウンドで cwnd 分を
   配送と見積もる)。cwnd ≈ BDP = rate × RTTprop ゆえ **weight ∝ cwnd ∝ RTT**。
4. 従って **RTT が大きいパスほど重み大 → deficit 大 → 全フローのピンがそこへ集中**。
   ソースに既知問題として明記:
   > "sym P=16 aggregation collapse: 17/0 pin split, confirmed via WLB_INSTR"
   > — 全フローが温まった 1 パスに固着 (冷えパスの重みが小さすぎて pick_pin が常に温パスを選ぶ)
   (xqc_scheduler_wlb.c L1000-1002)。

崩壊の「勝者」は**どのパスが最大 cwnd を持つか**で決まる。2 つの位相:

- **(a) ウォームアップ競争 (本番)**: パスが順次立ち上がる / 初期に 1 本だけ温まる場合、
  最初に cwnd が伸びたパスが一時的に最大重みになり以降を独占。本番は f0 (srtt 30ms,
  最低 RTT) が最速で温まったため f0 が勝った。
- **(b) 定常 cwnd/BDP (ラボ再来)**: 複数パスが同時に温まる場合、構造的に cwnd 最大なのは
  「最高 RTT (=最高 BDP)」のパス。→ 後述ラボ再来で B (42ms + jitter) に集中。

※「RTT でなく実績(cwnd)で効く」は正しいが、その帰結は「最低 RTT が勝つ」**ではなく**
「最高 cwnd (≒最高 RTT) が勝つ」。本番の f0 勝利は (a) の一過性ウォームアップ優位による。

## ラボ再来 (3-path netem, 本番 3x Starlink を模倣)

- 構成: `test/bench.sh collapse3` で 3 WAN に netem を適用し、mqvpn は 3 パス (eth1/3/4)
  のみ使用 (残り 9 NIC は残置、使うパスだけ絞る)。
  - A=eth1: `delay 30ms rate 458mbit` (本番 f0 相当)
  - B=eth3: `delay 42ms 15ms distribution pareto rate 400mbit` (本番 f2 相当, ジッター大)
  - C=eth4: `delay 35ms rate 450mbit` (本番 f3 相当)
- 計測: `test/measure-bottlenecks.sh 20` (iperf3 -P20 -R でクライアント→mnet 経由トンネル)。

結果 (20s, -P20 -R):

| 項目 | 値 |
|---|---|
| 合計スループット | ~341–406 Mbps |
| eth1 (A) | 2–6 Mbps (util 0–1%) |
| eth3 (B) | **364–410 Mbps (util 91–102%)** ← 崩壊集中先 |
| eth4 (C) | 6–12 Mbps (util 1–2%) |
| サーバー mqvpn CPU | 21% |
| ルーター CPU | 10% |

- wlb が **B (最高 RTT・ジッター) に 100/x で集中**し、B の netem 上限 (~400M) で総量が caps。
  3 パス全部使えば ~1.3 Gbps 出るはずが、崩壊で 1 パス分に留まる。
- サーバー/ルーター CPU は余裕 → ボトルネックは **wlb の単一パス固着そのもの**
  (シングルスレッド CPU 飽和ではない)。
- 勝者が本番 (A) と逆 (B) なのは上記 (a)/(b) の位相差: ラボは 3 パス同時立ち上げ →
  定常 cwnd/BDP で最高 RTT の B が勝った。コードの重みモデルと一致。

## 対処 (最小パッチ案)

- `wlb_compute_weight` に**冷えパス重みフロア** (例: `max(weight, max_weight/4)`) を追加 →
  ラウンドごとに最低量子を確保し、低 cwnd (低 RTT) パスへも比例配分される。
  両端同一バイナリのため 1 パッチ。ビルド → ルーター再デプロイ + サーバー容器 2 つの
  再ビルドで反映。パケット単位の経路変更ではないためフロー内 reordering 増は限定的。
- 補足: フロアで「最高 RTT パスへの一本化」を防ぐ方向性は正しい。フロア比を大きくすると
  低 RTT パスへの配分が増え、本番の A 集中 / ラボの B 集中いずれも緩和される。

## 残課題

- フロア値の調整 (帯域比が 3:1 でも f2/f3 へ配分するか、Starlink 帯域差への追随)。
- ラボでフロア適用ビルドを作り、崩壊が緩和されることを再計測 (measure-bottlenecks.sh で確認)。
- 4 並列時の溢れレイテンシ崩壊 (ソフトピン飽和時のキュー滞留) — フロア適用後に再計測。
- reinjection=deadline の生産適用 (採用指針 off との乖離) は別途。
