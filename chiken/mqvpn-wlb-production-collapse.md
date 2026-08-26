# mqvpn WLB フローピン集中崩壊 (本番: 3x Starlink の下りが 1 本に固着)

> 更新: 2026-08-26
> 対象ビルド: mqvpn v0.16.1 (router: mqvpn-0.16.1, xquic 9ed9642e65b), cc=bbr, scheduler=wlb,
> reinjection=deadline (採用指針 chiken/mqvpn-single-thread-cpu-bottleneck.md の "off" と不一致 — 別件),
> hybrid 無効, manage_routes=false。本番実測。

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

## 原因 (実装読解: xquic xqc_scheduler_wlb.c)

1. **TCP フローは 5-tuple FNV-1a hash → 1 パスに「ピン留め」** (flow table)。
   ピン先 = ディフィシット最大パス (wlb_pick_pin_path)。
2. **重み = cwnd 主体の LATE モデル** (wlb_compute_weight: cwnd×配送見込み, ssthresh=2×cwnd,
   loss<2% は無視)。RTT でなく「実績 (cwnd)」で効く → **乗ったパスほど重くなる正のフィードバック**。
3. 溢れ = **cwnd 詰まり時の「ソフトピン」のみ** (ピン張替えなし、空けば戻る)。
   ピン張替えは expire 60s / loss≥2% / PTO≥3 のみ。ラウンド再計算でもピン不変。
4. ソースに既知問題として明記:
   *"sym P=16 aggregation collapse: 17/0 pin split, confirmed via WLB_INSTR"*
   — 全フローが温まった 1 パスに固着する崩壊 (後から入った低速/冷えパスの重みが
   小さすぎて pick_pin が常に温パスを選ぶ)。
5. UDP/ICMP は UNPINNED → パケット単位 WRR で分散する (実トラフィックが TCP なので
   恩恵なし)。

本番観測 100/0 (f0 のみ) はこの崩壊の典型。f0 (srtt 30ms) が最初に温まり cwnd が
一人勝ち → 以後の全フローが f0 にピン → 実績でさらに重く… が永続化。

## 対処 (最小パッチ案)

- `xqc_scheduler_wlb.c` の `wlb_compute_weight` に**冷えパス重みフロア**
  (例: `max(weight, max_weight/4)`) を追加 → ラウンドごとにピンが 3 本へ比例配分。
  両端同一バイナリのため 1 パッチ。ビルド → ルーター再デプロイ + サーバー容器 2 つの
  再ビルドで反映。パケット単位の経路変更ではないためフロー内 reordering 増は限定的。

## 残課題

- フロア値の調整 (帯域比が 3:1 でも f2/f3 へ配分するか、Starlink 帯域差への追随)。
- 4 並列時の溢れレイテンシ崩壊 (ソフトピン飽和時のキュー滞留) — フロア適用後に再計測。
- reinjection=deadline の生産適用 (採用指針 off との乖離) は別途。