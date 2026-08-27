# mqvpn WLB スケジューラ P1+P3 検証 — 結論:  revert (容量比例ベースラインへ)

> 日付: 2026-08-28
> 対象ビルド: mqvpn v0.16.1 / xquic 9ed9642e65b
>   - 追加パッチ: `xquic-wlb-capacity-pinning.patch` へ **P1(負荷対応ピン) + P3(est_bw 高水位床)** を加えたもの
>   - 比較対象: `mqvpn-wlb-redesign-ab.md` の **NEW** (同パッチの P1/P3 なし版 = 容量比例ベースライン)
> 検証環境: MQVPN-NixOS test/ ラボ (WAN 3本 eth1/eth3/eth4)。
> 計測: `test/bench.sh` 適応ウォームアップ + 各シナリオ。本検証は高速化のため
> `BENCH_WARMUP=15 BENCH_WARMUP_MAX=25 BENCH_ADAPTIVE_WARMUP=0 BENCH_RUNS=1` で計測
> (doc NEW の `BENCH_WARMUP=60/max120 RUNS=2` とは窓が短く、run 間バラツキ ±15-20% に留意)。

## 1. 目的

`capacity-pinning` パッチ (est_bw EWMA + 探索スロット) に、さらに
- **P1**: ピン重みを「容量 × 余裕(headroom)」にする (`wlb_path_headroom`)
- **P3**: est_bw に「自経路実績の高水位床」を追加 (app-limited 崩壊防止)

を加え、高 RTT / 大容量パスの充填を改善できるか検証する。

## 2. 結果

| シナリオ | 指標 | doc NEW (P1/P3 なし) | 自ビルド P1+P3 (fractional) | 自ビルド P1+P3 (absolute 修正) |
|---|---|---|---|---|
| uneven | eth3(600M@200ms) util | **37%** (224M) | 14% (89M) | **5%** (33M) |
| | cap-prop RMSE | **27.6%** | 48.3% | 59.8% |
| | Jain | **0.929** | 0.852 | 0.725 |
| | RTT p50/p95/p99 | 403/434/489 ms | 103/—/— ms | 416/598/618 ms |
| latab | eth3(400M@200ms) util | **52%** (209M) | 30% (121M) | 19% (79M) |
| | RMSE | **24.5%** | 22.1% | 30.0% |
| | Jain | 0.838 | 0.842 | 0.752 |
| | RTT p50/p95/p99 | 401/419/433 ms | 102/107/133 ms | 25/29/30 ms |
| collapse3 tcp P=20 | TOTAL / Jain | 435 / 0.93–0.98 | 832 / 0.797 | (2nd run 0 フレーク) |
| collapse3 udp P=20 | TOTAL / Jain | 855 / 0.96 | 926 / 0.979 | — |

## 3. 診断

1. **P1 の fractional headroom は RTT バイアスだった (最初の実装)**。
   `(cwnd-inflight)/cwnd` は高 RTT パスほど inflight≈cwnd で常に低くなり、低 RTT
   小パスを過剰に優遇 → uneven で eth1(200M) が 104% にオーバーロードし eth3(600M)
   が 14% に餓死。 redesign が排除した「高 RTT パス飢餓」を再発させた。
2. **absolute-spare へ修正しても改善せず**。headroom は `est_bw` の倍率に過ぎず、
   200ms パスの `est_bw` は「実際に届く低スループット」(P=20 では ~25 フロー必要で
   埋まらない) に収束する。よって headroom レバーでは `est_bw` 限界を超えられない。
   (`mqvpn-wlb-capacity-latency-report.md` の「200ms パスは 1 フロー ~4–17Mbps、埋める
   には ~25 フロー」と一致。)
3. **reinjection 設定の食い違いが絶対比較を濁らす**。本ビルドはルーター側
   `reinjection=off` (mqvpn 既定) だが doc NEW は `deadline` 両端。off は総量を押し上げ
   (TOTAL 832/926 vs 435/855) するが、分配特性も変える。よって doc との差分は
   「P1+P3 の効果」 alone ではなく、reinjection 差も混入している。

## 4. 結論

P1+P3 は高 RTT / 大容量パスの充填を**改善せず、むしろ悪化**させた。headroom メトリク
は `est_bw` に支配され、RTT×フロー数という物理的限界を抜けられない。また fractional
実装は RTT バイアスで飢餓を再発させた。

→ **P1+P3 を全 revert**。容量比例ベースライン (`capacity-pinning` の P1/P3 なし版 =
doc NEW) が分布が最良であり、それに戻す。`patches/xquic-wlb-capacity-pinning.patch`
を `git checkout HEAD` で元のベースラインへ戻した (peak_bw / wlb_path_headroom は消去、
est_bw EWMA(15/16) + 探索スロットは維持)。

## 5. 今後の余地 (P1 を真に効かせるには)

高 RTT パス充填を本当に改善したいなら、ピン重みではなく **`est_bw` 自体の公正性** を
直す必要がある:
- est_bw が app-limited で低止まりにならないよう、容量推定を RTT 非依存かつ「未証明時は
  容量の下位床」で持っせる (P3 の高水位床を「自経路実績」ではなく「設計容量/過去最高」
  寄りにすると過剰配分の恐れ — トレードオフ)。
- あるいはフロー需要(巨象フロー)を考慮したビンパッキング (chiken の P2 案) だが、単一
  フローは 1 パス上限(順序保護)のまま。
- 制御 A/B: `capacity-pinning`(P1/P3 なし) を**同じ reinjection=off** で再ビルドし、
  本検証の P1+P3 ビルドと direct 比較すれば P1+P3 の純粋差分が確定する (未実施)。

## 6. 再現コマンド

```bash
test/up.sh                                  # ラボ再構築 (revert 済パッチを展開)
test/bench.sh uneven                        # eth3(600M) が ~37% に戻るはず (doc NEW 相当)
test/bench.sh latab                         # eth3(400M) ~52%
```
注意: `BENCH_RUNS=2` の 2 回目がトンネル一時スタルで 0 になるフレークあり
(udp run2=0 は redesign-ab でも既知)。信頼するには run 間で両端 mqvpn リセットが要る。
