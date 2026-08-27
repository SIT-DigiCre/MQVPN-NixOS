# mqvpn WLB スケジューラ再設計 — 関心事の分離 (2026-08-28)

> 対象: `third_party/xquic/src/transport/scheduler/xqc_scheduler_wlb.c`
> 新パッチ: `patches/xquic-wlb-capacity-pinning.patch` (既存 `xquic-wlb-rate-weight.patch` を置換)
> 代替ビルド検証: `/tmp/opencode/mqvpn` (v0.16.1 + xquic `9ed9642e65b`)

## 1. 現パッチの根本問題

`xquic-wlb-rate-weight.patch` は **4 つの別問題を 1 関数 `wlb_pick_pin_path()` に混在**させている:

| # | 関心事 | 現実装 | 問題 |
|---|--------|--------|------|
| 1 | capacity estimation | `peak_rate` (delivery-rate 高水準保持) | `255/256` 減衰で事実上**永久保持** → 過去の高値が容量推定を歪める |
| 2 | exploration | `eff = max(e, max_peak/2)` の 1/2 floor が「未使用回線を探る」副作用を兼務 | 探索と容量推定が同一パラメタに縛られる |
| 3 | anti-starvation | 同上 1/2 floor | 実容量 50Mbps の回線に 500Mbps 級の flow を割り当てかねない |
| 4 | flow allocation | `pin_credit` WDRR (重み = peak_rate) | 重み自体が (1) の歪みを引きずる |

特に `eff = peak_rate; if (e < max_peak/2) e = max_peak/2;` はアドバイスの指摘通り危険:
`A=1Gbps, B=50Mbps` でも `B >= 500Mbps` 相当の flow allocation を要求し、低速回線を queueing 崩壊させる。

## 2. 目的関数 (明示)

- **目的 A (主):** `max Σ throughput_i` — 各 path を容量上限まで埋める。
- **目的 B (副):** 高 RTT 回線への過剰集中による queueing 遅延増大を避ける。
- **構造制約:** 単一 QUIC connection が多数の inner TCP flow を搬送。pin は
  「各 path に飽和するだけの flow demand を与える」こと。flow 数比例配分は
  「各 flow の需要が同質 (bulk)」を前提とする最良 heuristic。

## 3. 再設計 — 関心事の分離

### (1) capacity estimation → `est_bw` EWMA (RTT 非依存)
`ctl_delivered` の wall-clock デルタで delivery rate (bytes/sec) を測定。
これは RTT に依存しない (cwnd/BDP を経由しない)。平滑化:
`est_bw = (15/16)·est_bw + (1/16)·rate`。
peak キャッシュを廃止し **current 容量**を追跡 → rich-get-richer ループが
**correcting** に反転 (低速回線は実測低のまま → 重み低 → 過剰割当てなし)。

### (2) per-packet WRR weight も `est_bw` に統一
`wlb_compute_weight` の LATE/cwnd モデル (weight ∝ cwnd ∝ BDP ∝ RTT) を削除し、
weight = `est_bw`。これで **per-packet 分散も容量比例・RTT 非依存**になり、
`latab` で観測された eth3(200ms) 餓死の根本原因 (WRR 重みの RTT 歪み) を除去。
(LATE モデル `late_estimate_dgram` / `late_ipow` は削除 — 死コード。)

### (3) flow allocation → `pin_credit` WDRR (重み = `est_bw`)
既存 WDRR 機構を維持し、重みを容量推定にする (容量比例配分)。

### (4) exploration / anti-starvation → 独立した確定スロット
1/2 floor を**撤廃**。代わりに「`WLB_EXPLORE_EVERY` (=8) 回に 1 回の pin を
**least-recently-pinned** な path に回す」確定探索を入れる:

```
pin_seq++;
if (pin_seq % EXPLORE_EVERY == 0)  pick argmin(last_pin_us);   // 探索
else                               WDRR by est_bw;               // 配分
```

- 遅い回線も定期的に flow を得て容量を**再証明** (exploration)。
- だが 50% floor のような過剰割当てはせず、rich-get-richer も解消
  (EWMA-current + 探索で低速回線が放置されない)。

### 閉ループの観測性
各 round で `est_bw[i]`, `pin_count[i]` をログ出力 (既存 `round_start` ログを拡張)。
`test/bench.sh` の per-path rx + srvCPU に加え、mqvpn ログを `grep` すれば
`scheduler → flow allocation → BBR → delivery → estimator` の閉ループを時系列取得可能。

## 4. 期待効果とトレードオフ

- 低速回線への過剰集中 (50% floor) 解消 → 実容量に即した配分。
- RTT 歪み除去 → eth3(200ms) も容量に応じて使われる (容量自体が小なら使われないのが正しい)。
- 探索による closed-loop 自己修正。
- 残課題: 本質的に flow 需要が不均質 (1 本だけ巨大 flow) な場合は count 比例配分が
  最適でない (需要比例が望ましいが scheduler は需要を知らない)。これは別フェーズ。

## 5. 検証計画
`test/bench.sh latab` (RTT 差孤立) / `collapse3` (本番再現) で per-path util と
tunnel RTT を既存パッチと比較。A/B 結果は別レポート (`mqvpn-wlb-redesign-ab.md`)。
