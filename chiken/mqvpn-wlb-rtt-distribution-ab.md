# mqvpn WLB pin ポリシー × RTT 配分の A/B 検証 (latab)

> 更新: 2026-08-27
> 対象ビルド: mqvpn v0.16.1 + `xquic-wlb-rate-weight.patch`
>   - **A** = 純容量ピン (`wlb_pick_pin_path` 重み = est_bw のみ)
>   - **B** = RTT ダンプピン (重み = est_bw × rtt_min/rtt, floor = max_w/8)
> ラボ: `test/bench.sh latab` (MQVPN-NixOS test/)

## 背景

「配分に RTT を考慮すべきでは」という直感から出発。現状の階層:

- **per-packet WRR** (`wlb_compute_weight` → `wlb_start_round`) は RTT/損失を込めた
  配信レート重みを使用（動的パケット振り分けで RTT を考慮済み）。
- **ピン** (`wlb_pick_pin_path`) は前回の調査(§2-G)で「容量比」に変更済み
  （= A。高 RTT パスを枯渇させないため）。

つまり「RTT を考慮」は WRR 側で既に効いている。ピンに RTT ダンプを入れた B で、
実際にレイテンシ/充填にどう効くかを A/B した。

## シナリオ `latab` (RTT 差を孤立)

容量は collapse3 と同一、RTT のみ拡大して RTT 差を顕在化:

| パス | RTT | 容量(ceil) |
|---|---|---|
| eth1 | 10ms  | 458M |
| eth3 | 200ms | 400M |
| eth4 | 50ms  | 450M |

測定: バルク埋め (`iperf3 -P 20 -R -b 1200M`, 40s) 負荷下で
トンネル RTT (`ping TARGET` の p50/p95/p99) と小パケット UDP jitter
(`iperf3 -u -l 64 -b 10M`) を取得。per-path rx / per-core busy% も記録。

## 結果

| ビルド | eth1 util | eth3 util | eth4 util | TOTAL | RTT p95/p99 (ms) | UDP64 jitter | srvCPU |
|---|---|---|---|---|---|---|---|
| **A** 純容量ピン (2c) | 97% | **3%** | 36% | 624 | 252 / **402** | N/A | 150 |
| **B** RTTダンプピン (2c) | 97% | **1%** | 41% | 637 | 107 / **212** | 11.9 ms | 82 |
| **B** RTTダンプピン (6c) | 97% | **5%** | 65% | 764 | 252 / 263 | 29.9 ms | 112 |

(6c vs 2c の差は mqvpn インスタンスの CPU 余裕であり pin ポリシー比較は
同コア数同士 = A@2c vs B@2c が公正)

## 推論

1. **B は tail 遅延を半減** (p99 402→212ms)。ピンで高 RTT パス(eth3)への
   フロー貼り付けを減らした効果が出た。
2. しかし **eth3(200ms) はどちらも 1–5% で崩壊**。ピンをどう変えても埋まらない。
3. 原因は **per-packet WRR 重みが RTT を重く見積もる**ため。200ms パスへは
   量子が極端に少なくなり → cwnd が開かず → 測定スループットが低く →
   重みが更に低くなる **正のフィードバック崩壊**（＝元の「1 パス崩壊」と同種）。
   故に純容量ピン(A)でも eth3 は枯渇する。
4. 結論: 「RTT を配分に考慮する」は WRR 重みで**既にやりすぎ**。本質的な fix は
   WRR 重みを「瞬間スループット」ではなく**容量(est_bw)ベースに平準化**し、
   高 RTT パスを潰さないこと。その上でピンが低 RTT をやや優遇するのが正解。
5. 6c はスループット向上 (624→764, eth4 36%→65%) をもたらした。pin 比較は
   同コア数で行うべき。

## 補足

- **サーバ起動は実環境に合わせ 2 vCPU (`-smp 2`)**。-current 実機は
  サーバ側 2 vCPU (Ryzen 9 7900) / ルータ i5-12400 相当。本番は 6 vCPU 予定
  （その際は起動スクリプトの `-smp` を切り替え）。故に下表の **A@2c / B@2c が
  代表値**。`srvCores` は現状 2 コア分のみ表示（実環境と一致）。
  B@6c 行は 6 vCPU で走らせた参考値（mqvpn インスタンスの CPU 余裕で全体
  スループットが上がる傾向を示すため）。
- B は `xquic-wlb-rate-weight.patch` の `wlb_pick_pin_path` に
  `srtt = xqc_send_ctl_get_srtt(path->path_send_ctl)` で rtt_min を求め、
  `eff[i] = eff[i] * rtt_min / srtt`（floor = max_w/8）を追加。
- トンネル RTT はクライアントから `TARGET=192.168.100.1`(mnet) への ping で
  計測（トンネル経由であることを RTT 値で確認）。
- A の UDP jitter は取得失敗(N/A)。小パケット UDP プローブは負荷下で
  受信側集計行の取得が不安定な場合あり。

## 次ステップ

- **WRR 重みを est_bw(容量) ベースに平準化**し eth3 を埋める修正 →
  その後 A/B を 6c 環境で揃えて公平に再計測。
- あるいは B(ピン RTT ダンプ) のまま他検証を優先、または A に戻す。
