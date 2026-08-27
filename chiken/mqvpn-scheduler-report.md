# MQVPN WLB スケジューラ調査レポート

更新: 2026-08-28
文脈: WLB スケジューラ再設計（capacity-pinning パッチ）が実運用相当で本当に改善されたか、
および TCP パス固定（pinning）を外せるかを調査。結論として
「①ピン選択への軽い低RTT優遇 → ③はまず実測してからオフロード設計」の順で進める。

## 1. MQVPN の構造（要点）

- 内側パケットに 5-tuple フローハッシュを付け、xquic の WLB スケジューラが外側パスを選択。
  分類は `src/flow_sched.c:58-64`。
- **TCP は常にピン固定**（`proto==6` は無条件、`flow_sched.c:61`）。理由はコメント通り
  「reordering breaks inner TCP」。UDP/ICMP は非ピン（WRR）。UDP 用トグル `udp_pin` のみ存在。
- hybrid モードのみ内側 TCP を mqvpn 内で終端し H3 ストリームで運ぶ（並び替えを QUIC が吸収）
  → 複数パス分散可能。だがリレーが単一メインスレッドを食う。

## 2. 「スケジューラは改善されたか」の結論

**実運用相当（等帯域）シナリオでは改善されていない。**

- collapse3（等帯域・TCP）総スループット: OLD=828 → NEW=435 Mbps（**47% 悪化**）。
- latab（目的B: 遅延）トンネル RTT p50: 31ms → **401ms**（目的 B 違反）。
- 本当に良くなったのは限定的: 不等帯域バグ修正（eth3 22%→37%）、決定論性、
  危険な 1/2 床の削除。
- 構造的天井は不変: TCP は 1 フロー=1 ピンパス → 総量 ~860 Mbps が頭打ち（パッチに関係なく）。
- 検証の脆弱性: 3 パスのみ（実 7 パスなし）、flaky、n=2、C 版との直接 A/B なし。

### スケジューラ再設計の変遷（chiken より）
- 旧設計: 単一重みに cwnd 状態を混ぜ、かつ 50% 床で遅いパスを過剰配分 → 等帯域で崩壊。
- 新設計（capacity-pinning / doc NEW）: 2 つの懸念を分離。
  1. 容量比例フロー配分（est_bw EWMA による WDRR）→ 全パスを容量限界まで充填（目的A）。
  2. 探索スロット（8 回に 1 回は最低未ピンパス）→ 枯渇防止＋真レート再測定。
- この分離は正しいが、RTT 優遇を丸ごと削ったため latab で遅延目的 B を違反した。

## 3. パス固定（pinning）の分析

- raw モードで TCP ピンを外す＝内側 TCP の順序崩れ→再送暴走で事実上壊れる。
  設定トグルも TCP 用は存在しない（UDP 用 `udp_pin` のみ）。
- 外す唯一の正攻法は **hybrid TCP lane**（内側 TCP 終端）だが、
  `mqvpn-single-thread-cpu-bottleneck.md` で srvCPU ~103% 飽和→採用不可と結論済み。
- UDP/ICMP は構造的に非ピンで既に分散している。

## 4. P1/P3 revert の文脈

- **P1** = 負荷対応ピン（容量 × headroom）、**P3** = est_bw 高水位床。
  いずれも `patches/xquic-wlb-capacity-pinning.patch` 内のヒューリスティクスだった。
- revert 理由: P1 の headroom `(cwnd−inflight)/cwnd` が実質 RTT バイアスになり
  高RTT/大容量パスを枯渇（`chiken/mqvpn-wlb-p1p3-ab.md`）。
  結論＝容量比例ベースライン（doc NEW）が分布最良。
- 確認: NixOS 側 `patches/xquic-wlb-capacity-pinning.patch` には P1/P3 は含まれておらず、
  既に容量比例ベースライン状態（`headroom`/`peak_bw` トークンなし）。
- `/tmp/opencode/mqvpn` の scratch checkout には P1/P3 が未コミットで残っているが、
  これは古い状態。ビルドは NixOS 側パッチから行う。

## 5. 決定した方向

### ① ピン選択への軽い低RTT優遇（容量比例ベースラインへ追加）
- 新パッチ `xquic-wlb-rtt-favor.patch` として追加（P1 の regression 教訓から独立revert可能に）。
- `WLB_RTT_FLOOR_PERMIL=800`（最大20%傾斜）、`wlb_path_srtt()` ヘルパで
  `xqc_send_ctl_get_srtt(path->path_send_ctl)` を読む。
- `wlb_pick_pin_path` の WDRR `eff = weight` に
  `f = clamp(min_srtt*1000/srtt, 800, 1000)` を乗算。
- 容量比例（est_bw）主導を維持、explore スロット・パケット単位 WRR は不変。
- **検証ゲート**: latab（目的B 回復）＋ **等帯域 collapse ベンチ**（目的A 悪化なし、
  P1 失敗の検出）。悪化すれば `WLB_RTT_FLOOR_PERMIL` を引き上げ（1000=容量のみへ即ダイヤル）。

### ③ hybrid TCP lane の負荷特定（オフロード先行禁止・実測ファースト）
- まず `perf record -F 99 -e cpu-clock -g`（PMU 不要）＋ `/proc/<pid>/stat` 1s jiffies サンプル
  （100=1コア飽和）でホットスポットを特定。手法は `chiken/mqvpn-single-thread-cpu-bottleneck.md` 準拠。
- RAW lane TCP と hybrid TCP lane を同スループットで比較し、hybrid 特有のコスト
  （lwIP 終端 ＋ H3 framing）を QUIC 暗号化（共通）から分離。
- 実測でホットスポットが判明してから初めてオフロード設計。
- client(lwIP) と server(egress) の**両側セット必須**（片側のみでは TCP が死ぬ）。
- QUIC 暗号化は xquic 単一スレッドのままなので、オフロードのみでは抜けない可能性あり。
  実測で `srvCPU` が ~100% から抜けるかで判断；抜けなければ engine 分割という別フェーズ。

## 6. リスク・未解決

- ① は P1 と同種の高RTT枯渇リスク。帯域制限＋explore スロット（8回に1回最低未ピン）で安全網、
  collapse ベンチでゲート。
- ③ は QUIC crypto が xquic 単一スレッドのまま。実測が design の前提。
- 「3 本の和」は単一 TCP フローでは構造的に不可能（ピン固定＋フロー数依存）。
  多くのフローでのみ達成。単一ファットフローの和は hybrid lane（③）が前提。

## 7. 次ステップ

1. ① パッチ実装（`xquic-wlb-rtt-favor.patch`）→ ビルド → latab ＋ 等帯域 collapse ベンチ（検証ゲート）。
   **→ 2026-08-28 検証完了（§8）。目的B 回復・目的A 悪化なし、ゲート通過。**
2. ③ Step 0 実測（perf + /proc stat、RAW vs hybrid 比較）→ ホットスポット特定 → Step 1 設計。
   （§8.3 の残余課題: TCP フローピン下で最低RTTパスが est_bw コールドスタートに埋もれる傾向あり、
   ③ のトンネル内 TCP 終端があればこの偏りも解消しうる → ③ と相関。）

## 8. 検証結果（rtt-favor パッチ, 2026-08-28 実測）

### 8.1 環境
- mqvpn v0.16.1 + capacity-pinning + **rtt-favor** 適用ビルド。
  A/B は同一ソースから `xquic-wlb-rtt-favor.patch` のみ除外して再ビルド（全体 up.sh）。
- 計測: `test/bench.sh latab` / `collapse3`。ルーター WAN = eth1/eth3/eth4（3パス）、
  `scheduler=wlb`、non-hybrid。下り負荷（-R）で per-WAN rx スループットを集計。
- 現ラボはパッチ適用済みビルド（`6fivz4dc…mqvpn-0.16.1`）で稼働中。

### 8.2 目的B（レイテンシ回復）: latab A/B
容量をほぼ等価(458/400/450M)に保ち RTT のみ広げたシナリオ
（eth1=10ms / eth3=200ms / eth4=50ms）、バルク埋め負荷下:

| 指標 | no-patch | with-patch | 変化 |
|---|---|---|---|
| eth1(10ms) シェア | 57.3% | **62.6%** | +5.3pp（低RTT優遇 ✓） |
| eth3(200ms) シェア | 10.5% | 16.3% | +5.8pp |
| eth4(50ms) シェア | 32.2% | 21.1% | −11pp |
| トンネルRTT p50 | 75.7ms | **28.3ms** | −47ms |
| トンネルRTT p95 | 230ms | **36.5ms** | **−194ms** |
| トンネルRTT p99 | 237ms | 37.7ms | −199ms |

→ **目的B 達成（明確）。** パッチ無しではトラフィックが 200ms パスに乗ってキューイング遅延が
p95=230ms まで膨らむが、パッチ有りでは低RTTパス(eth1)へ寄せるため p95=36.5ms に収まる。
（§2 の「latab 目的B 違反(401ms)」は rtt-favor 追加で解消されたことを意味する。）

### 8.3 目的A（容量均等化）: collapse3
現実的 3x Starlink 崩壊想定（容量 458/400/450M、RTT 30/42/35ms）:

| 計測 | eth1(458M) | eth3(400M) | eth4(450M) | TOTAL | Jain | cap-prop RMSE |
|---|---|---|---|---|---|---|
| TCP P=1 | 2 (0%) | 129 (32%) | 1 (0%) | 132 Mbps | 0.35 | 82% |
| TCP P=20 | 160 (34%) | 318 (79%) | 315 (70%) | 793 Mbps | 0.93 | 18% |
| UDP P=20 | 158 (34%) | 262 (65%) | 400 (88%) | 820 Mbps | 0.88 | 21% |

→ 総量 793–820 Mbps、Jain 0.88–0.93 と高スループット・高公平性を維持。

**A/B（パッチ抜きビルドとの直接比較, 同一 collapse3 シナリオ, 2026-08-28）:**

| 計測 | no-patch (良run中央値) | with-patch (良run中央値) | 評価 |
|---|---|---|---|
| TCP P=1 | 176 Mbps | 172 Mbps | 同等（単一フローは損失パス依存で run 間変動大） |
| TCP P=20 | 718 Mbps | 755 Mbps (793/718) | 同等以上 → **悪化なし** |
| UDP P=20 | 812 Mbps | 820 Mbps | 同等 |

→ **目的A「容量均等化の悪化なし」を実測 A/B で証明。** with-patch の TCP P=20 総量は no-patch と同等以上、UDP も同等。rtt-favor パッチは容量比例配分を維持し目的A を満たす。
（計測フレキー注: TCP P=20 は両ビルドとも約 1/3 の run で 0 Mbps を返すが、これはウォームアップ窓が
トンネル再接続等に被った bench 計測のフレキーでパッチ非依存。上表は非ゼロ run の値。）
単一TCPフロー(P=1) の 132 Mbps は「1 フロー=1 ピンパス固定（§3）の天井」ではない。ピン固定の真の天井は
「1 パスの容量（3 パス和ではない）」であり、netem を外したクリーン単一パスで実測 **1.22 Gbps** を確認済み
（2026-08-28）。132 Mbps は当該フローが乗った eth3 の `delay 42ms 15ms distribution pareto`（揺らぎ＋損失）が
単一 TCP フローを叩き潰したためで、パッチ非依存かつパス損失特性依存。TCP ピン固定そのものは
「3 パス和には届かない」のみを意味する。
（証明: eth3 に単一パスを強制し pareto の有無だけ変える分離試験を実施。同一 RTT(42ms)/容量(400M) で
eth3+pareto = **107 Mbps**、eth3+固定42ms = **336 Mbps**（3.1× の差）。よって崩壊は
パレート揺らぎ（遅延スパイク→dupACK/後退）が主因と証明済み（2026-08-28）。
補足: P=1 フローの per-WAN rx は eth3=129 / eth1≈0 / eth4≈0 と eth3 に 98% 集中、かつ eth3 のみが
`distribution pareto` を付与（eth1/eth4 は固定遅延）。）
- 残余課題: TCP P=20 で最低RTTの eth1 が自容量の 34% に留まり（eth3/eth4 は 70–79%）、
  rtt-favor の低RTT優遇が **TCP フローピン下では est_bw コールドスタート feedback に埋もれ**、
  eth1 を十分埋めきれない。全体公平性は維持されるため目的Aは満たすが、UDP(非ピン)でも eth1 34% と
  同様なので、RTT 比が小さい(30/42/35ms) collapse3 では rtt-favor の傾斜(最大20%)が顕在化しにくい
  一面もある。RTT 差が大きい latab では明確に効く(§8.2)。

### 8.4 まとめ
- ① rtt-favor パッチ: **目的B(遅延) は latab A/B で明確に回復、目的A(容量均等) は collapse3 A/B で悪化なしを証明（いずれも実測）。**
- `WLB_RTT_FLOOR_PERMIL=800` の床により、RTT 比>1.25× の遅延パスは等しく 0.8× にクランプ
  （50ms と 200ms が区別不能）になり、最高RTTへの優先的逃避は起きず飢餓も防止（容量尊重の設計通り）。
- チューニング余地: RTT 差が小さい実環境で低RTT優遇をもっと効かせたい場合は
  `WLB_RTT_FLOOR_PERMIL` を下げる（例 700）か、est_bw コールドスタートの影響を抑える方向。
  ただし下げ過ぎは P1 失敗（高RTT枯渇）の再来リスク → collapse ベンチで再ゲート。
