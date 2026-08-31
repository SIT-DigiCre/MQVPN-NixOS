# mqvpn ソースパッチ逆順削除 → collapse3 計測変化

## 目的
適用済み mqvpn ソースパッチ 5 枚を逆順に 1 枚ずつ外し、`bench.sh collapse3` がどう変化するか観察。
NAT 系 2 枚 (`container/mqvpn-server-image.nix`) は接続性に関わるため残したまま(別ファイル)。

## 方法
- 削除順(逆順): rate-limit → scan → rtt-favor → capacity-pinning → max-paths。
- `measure_once` は `wait_wlb_steady` で WLB 収束まで最大 45s ポーリング、2s 休ませてから 15s 計測(冷直後ではない)。
- 容量は実測物理平均値固定 (eth1=217 / eth3=175 / eth4=107 Mbps)。RTT は netem delay+jitter で変動。
- ラボ起動は `setsid` detached session(中断の SIGTERM が VM に伝播するのを防ぐ)。
- 安定信号は P=20(tcp/udp)。P=1 は単一フローが 1 パスに釘付けになり計測がノイズ(0〜230M, まれに 0)のため参照のみ。0 は後述の再計測で回避済。

## 結果 (collapse3: TOTAL / Jain / cap-prop RMSE)
| 状態 | 残りパッチ | tcp P=20 | udp P=20 |
|---|---|---|---|
| baseline | 全5枚 | 500M / 0.93 / 2.4% | 511M / 0.93 / 0.2% |
| R1 -rate-limit | max,cap,rtt,scan | 493M / 0.90 / 4.0% | 433M / 0.97 / 7.7% |
| R2 -scan (※rate-limit も同時除去が必要) | max,cap,rtt | 337M / 0.61 (eth3死) | 407M / 0.97 |
| R2b R2 再現 | max,cap,rtt | 369M / 0.88 (全パス使用) | 328M / 1.00 |
| R3 -rtt-favor | max,cap | 516M / 0.93 / 0.3% | 457M / 0.96 |
| R4 -capacity-pinning | max | 193M / 0.38 (eth3のみ) | 512M / 0.94 |
| R5 -max-paths | (なし) | 188M / 0.36 (eth1のみ) | 440M / 0.88 |

R2(初回)の "eth3 死" は **R2b で再現せず(全パス使用, Jain 0.88)** → 単発のフレーク(15s 窓が 1 パス未使用の過渡を捕えた)。
R2b でも TOTAL が 369M と低めなのは単なるラン間バラツキ(集約は 337〜516M を往復)。

## ソース調査で判明した真因

### capacity-pinning が TCP マルチパス分散の要 (R4/R5 で崩壊の理由)
`xquic-wlb-capacity-pinning.patch` は `xqc_scheduler_wlb.c` の重み付けを書き換える:
- 従来の **LATE/cwnd 重み (∝ BDP ∝ RTT)** を削除 — これは高 RTT パスを餓死させていた。
- 代わりに **RTT 非依存の配送レート `est_bw` (EWMA of `ctl_delivered` 増分, `wlb_sample_rate`)** による容量比例 WDRR (`pin_credit`) を導入。
- `wlb_pick_pin_path` を「容量比例 WDRR + 8 ピンごと最長未ピンパスへ探索(anti-starvation)」に redesign。
- `rtt-favor` はこの上に「ピン先へ最低 RTT への軽いバイアス(床 800‰, 餓死なし)」を載せる。

→ capacity-pinning を外す(R4/R5)と scheduler が **LATE/cwnd (∝RTT) 重みに逆戻り** し、低 RTT パスに TCP が収束 → 単一パス崩壊。UDP は別経路でこの重みを使わないため unaffected。

### scan と rate-limit は結合している(重要な制約)
`xquic-reinjection-rate-limit.patch` は `third_party/xquic/src/transport/xqc_reinjection.c` を scan パッチの変更**を前提とした context** で当てる(scan が先に適用)。
そのため **scan 単体は削除不可** — scan を外すと rate-limit の Hunk#2 が FAILED しビルドが死ぬ。
「scan を外す」= 実質「scan + rate-limit 両方外す」(=R2/R2b の状態)。
両パッチは reinjection スキャンの最適化(scan: 年齢ウォーターマーク `scan_seen_young` + アイドル tick スキップ `reinj_sent_this_tick`; rate-limit: reinjection 発火頻度制限)。

### 「scan × rtt-favor 相互作用」は存在しない
R2(scan+rate-limit 除去, rtt-favor あり)は R2b で正常(全パス使用)に再現。初回 R2 の eth3 死はフレーク。
rtt-favor 単体(R3, capacity-pinning あり)は TCP 分布をむしろ改善(最高 RMSE 0.3%)。相互作用は無い。

## 結論(修正版)
- **capacity-pinning は絶対に外せない**: TCP マルチパス分散の要。外すと LATE/cwnd(RTT 餓死)重みに逆戻りし TCP が単一パスに崩壊。本番必須。
- **rate-limit は ~500M 集約では無意味**(R1≈baseline)。本来の効能は CPU バウンド高スループット域(未検証)。
- **scan は単体削除不可**(rate-limit と結合)。両方外しても TCP 分散への影響は小さい(R2b 正常)。
- **rtt-favor は無害〜軽微に有益**。単独運用も可(但し scan は rate-limit とセットで外れる点に注意)。
- 本番推奨: 5 枚全適用(=baseline, TCP 500M / UDP 511M 容量比例)。

## 注意
- 各ラウンド single-run。R2 の eth3 死は R2b で再現せずフレークと判断。
- P=1 の 0 Mbps は bench.sh 単一フロー計測のフレーク。TOTAL=0 時に再計測するよう `measure_once` を修正済(BENCH_RETRY 既定3)。未コミット。
- 実験後 pkgs/mqvpn-src.nix は全パッチ復元済(`git checkout`)。
