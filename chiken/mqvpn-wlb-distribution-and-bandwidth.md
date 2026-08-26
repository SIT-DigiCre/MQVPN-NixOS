# mqvpn WLB 逆探査：分散条件と多セッション実効帯域拡大

> 2026-08-27, mqvpn v0.16.1 / xquic 9ed9642e65b, scheduler=wlb
> ソース: github:mp0rta/mqvpn @v0.16.1
>   - third_party/xquic/src/transport/scheduler/xqc_scheduler_wlb.c
>   - src/flow_sched.c (po_flow_hash 割り当て)
> 先行調査: chiken/mqvpn-wlb-production-collapse.md (崩壊＝単一パス固着) の「逆」
> ＝「いつ複数パスに分散されるか」と、多量セッション時の実効帯域拡大策。

## 0. フロー分類の正体 (flow_sched.c)

`flow_hash_pkt()` の出力で以降の振る舞いが決まる (`flow_sched.c:58`:
"TCP always pinned … UDP pinned only when udp_pin=true"):

| 内側パケット | ハッシュ | 結果 |
|---|---|---|
| TCP (proto 6) | 5-tuple FNV1a | **PINNED** (フロー単位で 1 パスに固定, 60s idle) |
| UDP (proto 17), `udp_pin=false` (既定 wlb) | `MQVPN_FLOW_HASH_UNPINNED` (0xFFFFFFFF) | **UNPINNED → パケット単位 WRR** |
| ICMP / その他 | UNPINNED | 同上 |
| IPv4 `len < ihl+4` / IPv6 `len < 44` / ext-header で直 TCP/UDP でない | UNPINNED または 0 | 同上 (TCP でも截断ヘッダなら漏れる) |
| IPv4 非先頭フラグメント | IP/ID で PIN (別ハッシュ) | PINNED (但しポート非考慮) |

→ **内側 UDP/ICMP は構造的に決してピンされず、常に全パスへ WRR 分散される。**
これが最大の「逆条件」: UDP こそ「崩壊しない (=常に分散する)」唯一のトラフィッククラス。

## 1. 逆の条件：いつ複数パスへ分散されるか

### (1) 内側 UDP/ICMP — 常に分散 (最強の逆条件)
`wlb_wrr_select` のみ (フロー表へ挿入しない)。各 UDP データグラムは `deficit`
最大の送信可能パスへ独立に配送。TCP が 1 パスに固着していても、トンネル内 UDP
ペイロード (DNS, DoT/DoH, QUIC, ゲーム UDP, RTP/Zoom/WebRTC, 内包 WireGuard/OpenVPN-UDP,
NTP, SNMP…) は **3 Starlink の和 ~1.3 Gbps を常に aggregatie**。
- WRR の重み `weight ∝ rate` (patched) または `∝ cwnd ∝ BDP` (unpatched) ゆえ、
  分割は重み最大パスに寄る (均等ではない)。UDP は順序不要なので再構成崩れは許容。
- 単一 UDP 5-tuple フロー内でもパケットが別 RTT のパスへ散る → 到着ジッター。
  QUIC(内トンネル) 等はこのジッターを被る。

### (2) 截断/拡張ヘッダ TCP — 漏れて分散
`flow_sched.c:82-84,107-109` で短い/ext-header パケットは UNPINNED → パケット単位 WRR。
頻度は低いが、IPv6 ext-header (AH/ESP/ルーティング) を通す TCP は順序保持を失って分散。

### (3) ソフトピン溢れ — 「負荷駆動」の分散
`wlb_wrr_select` でピン済フローのパスが cwnd 封鎖なら、その 1 パケットだけ
`pin_flow=false` にして別送信可能パスへ WRR 配送、**再ピンせず**。
→ 勝者パスの cwnd が飽和すると他パスへ溢れる。セッション数↑ → 勝者 cwnd 飽和↑ →
溢れ↑ → 多パス利用率↑。欠点は別 RTT パスへの溢れが TCP 再構成を崩し、ジッター崩壊を生む。

### (4) 損失/PTO 退避 → 再ピン (動的再分散)
- `wlb_flow_expire` L352-356: 損失率 ≥2% のパスのフローを tombstone → 次パケットで WRR 再ピン。
- PTO 退避 L948-957: ピン済パスが連続 PTO≥3 なら退避+再ピン (ブラックホール/フェイルオーバ)。
- 復旧 grace L924/984: パス復帰後 1s のパケット単位 WRR + 復帰パス優先。

### (5) TCP ピンは「共有赤字」で他パスへ溢れるが、バースト/ウォームアップで集中する
- トンネルは **1 QUIC 接続** (`conn->cid`; トンネル L1376 も connect-tcp L1472 も同一 cid の
  H3 ストリーム)。故に WLB スケジューラ `s` は**トンネル内全 TCP フローで共有**。
- ピンはフロー開始時に `wlb_pick_pin_path` (xqc_scheduler_wlb.c:786) で「最大 deficit パス」を
  選ぶが、その deficit は `wlb_wrr_select` が**パケット送信ごとに -1** する (同 c:840)。
  共有 `s` 上で既存フローが送るたび赤字が回転するため、**後のフローのピンは別パスを見る** →
  設計上は「weighted alternation」(同 c:782-798 コメント "flows alternate naturally")。
  ⇒ **「フローいっぱい生えたら別パスへ溢れる」は正しい挙動** (ユーザー指摘の通り)。
- 但し 1 パス化する弱点が 2 つ:
  1. **ウォームアップ盲目窓**: 2 つ目パス出現後 ~1s は `pick_pin` が「全フローを温プライマリに
     割当」(同 c:1050「assign EVERY flow to the warm primary」、17/0 集約崩壊を WLB_INSTR で
     確認済み)。
  2. 溢れは**重み付きで粗く**、かつピンはフロー開始時の瞬間赤字で決まる → **一斉接続バースト**
     (speedtest) では赤字回転が間に合わず最初の群が固まる。
- 実測 (collapse3, 合計 1308M):
  - 同期 TCP -P20 = 675M (eth4=403 / eth3=215 / eth1=57) — 偏りつつ 3 パスに分散。
  - 時間 1s ずらし TCP N=20 = 640M (eth3=398 / eth1=106 / eth4=136) — **分散先は変わる**
    (同期は eth4 偏り、ずらしは eth3 偏り) が、重み付き粗溢れのため比例には遠い。
  - ⇒ speedtest が 1 パス相当になるのは「決定論的固定」ではなく、**バースト集中 +
     ウォームアップ窓**による見かけの 1 パス。到着タイミングで分布は変わる (故にずらしで
     分散先は変化する)。

### (6) Hybrid TCP lane — TCP を分散させる手段
`docs/control-api.md:607`: hybrid の `Tcp` ポリシー:
- `raw` → 内側 TCP を CONNECT-IP データグラム経由 (＝§0 の PINNED, 1 パス固着)。
- `stream` / `auto` → 内側 TCP を **TCP lane で終端**し、H3 ストリームとしてトンネルに載せる
  (src/hybrid/tcp_lane.c: lwIP 終端 + `xqc_h3_request_send_body`)。

lane は内側 TCP を mqvpn が両端で終端するため、内側 TCP はもう「生パケット」ではない。
マルチパススケジューラがパケット単位で各パスに振り分けても、再構築は mqvpn/QUIC
ストリーム側で行われるから**内側 TCP は並び替えを観測しない**。故に lane 経由の TCP は
PINNED を回避でき、UDP 同様に全パスへ分散される。`docs/report/...rtmp...:180` も
「TCP ベースのプロトコルには hybrid TCP lane を有効にせよ」と明記。

実測 (同 collapse3, `Tcp=stream` 両端):
- TCP -P1 = **78 Mbps** (eth1=40 / eth3=3 / eth4=35) — **3 パス全てに分散** (1 パス崩壊は解消)。
- TCP -P20 = **191 Mbps** (eth1=95 / eth3=23 / eth4=73) — 同上。
- UDP -P20 = 2021 Mbps (lane 影響なし, 従来通り分散)。
- ⇒ 分散は確かに達成される。但し **転送スループットが大幅低下** (raw の 223/675 Mbps に対し
  78/191 Mbps)。原因は lane がユーザー空間で TCP 終端 + H3 リレーを行う CPU オーバーヘッド
  (計測中 srvCPU 103% 飽和)。
- **mqvpn コアは libevent 単一イベントループ** (`platform_linux.c:729` `event_base_dispatch`)。
  `src/` に `pthread_create` は無く、xquic もスレッドを使わない → 通常運用は厳密にシングル
  スレッド (複数コアは ECMP で複数インスタンスへ強制分散させてのみ活用)。
  **hybrid lane のみ例外**: lwIP の UNIX ポートが `pthread_create` を呼ぶ
  (`third_party/lwip/.../unix/sys_arch.c:207`) ため、lane 有効時は lwIP スレッドが引き込まれる。
  但し実際のリレー (H3 書込み + QUIC 送信) は**メインの単一 libevent スレッド上**で行われ、
  そこが飽和する (計測 srvCPU 103%)。故に lane オーバーヘッドはメインスレッドに集中し、
  余剰コアでは並列化されず、高コア環境でも単一トンネルは効かない。
  ⇒ hybrid は「1 パス問題」の正攻法だが、**メインスレッドがリレーで飽和するため実質採用不可**。
  (docs の実機ボンディングは mqvpn がマルチスレッドで動く前提の話。)

### 逆条件まとめ
分散が起きるのは:
1. 内側 UDP/ICMP (常に, 最強)
2. 截断/ext-header TCP (常に, 稀)
3. 高負荷で勝者 cwnd 飽和 (ソフトピン溢れ)
4. 勝者劣化 (損失≥2% / PTO≥3) → 退避再ピン
5. 復旧時 grace 再分散
6. **Hybrid TCP lane (`Tcp=stream`)** — TCP を全パスへ分散させる手段 (但要 CPU)

## 2. 多セッション時の実効帯域を太くする方法

崩壊下の天井は 1 Starlink (~458 Mbps)。これを 3 本の和 (~1.3 G) へ近づける策。

### A. 根因: 重みを ∝ スループット(rate) に (BDP/cwnd ではなく)
`wlb_compute_weight` の返値 N (T=max_rtt/2 で配送期待パケット数) は `N ∝ cwnd ∝ BDP`。
配送*率* = N/T ∝ cwnd/rtt = rate。コードは T で割らず、しかも T を全パス共通の
max_rtt/2 にしているため低 RTT パスほどラウンド数が詰まり重みが歪む。
**正解: 重みを経路の推定スループットにする。** 帯域同値な Starlink なら重み≈等 →
ほぼ均等分割 → 和帯域到達 (UDP/非ピンでは既にこれに近い)。

### B. 重みフロア (doc 案) — 即効 palliative、併用
`max(weight, max_weight/4)` で冷/低RTT パスに最低 25% 量子を確保 → 一部がそちらへ。
1 パッチ両端、容易。但し比は恣意的で帯域差へ追従しない。

### C. ピン再分散 / 期限短縮
60s idle 期限 + 単一パス期間留保で早期ピンが sticky。安価な修理:
- `force_refresh_paths` (新パス/復旧) 時に既存ピンの一部も再評価する。
- WLB_FLOW_EXPIRE_US 短縮、または「K ラウンド毎に数%のフローを再ピン」を追加。
 但し再ピンは回転後の赤字を見るので別パスへ動く可能性はあるものの、active フローには
 効かずバースト集中の根本解ではない。**真に効くのは `pick_pin` 自身を「容量比例
 ラウンドロビン」に変えること** (§2-G)。

### D. UDP 経路の活用
UDP は既に分散するため、順序非依存/ジッター許容トラフィック (QUIC, RTP, ゲーム UDP)
は UDP でトンネル内を通すだけで自然に部分的集約を得る。

### E. ソフトピン溢れのチューニング (負荷駆動集約の獲得)
高セッション数では溢れが既に帯域を広げる。ジッター崩壊無しで帯域を得るには:
- 溢れ先を「最高 deficit」ではなく「送信可能別パスの中で最低 RTT」にする →
  クロスパス RTT 差最小化 → 再構成崩れ低減。
- 溢れ深さを cap (例: 勝者 cwnd 封鎖が X ms 超でのみ溢れ)。

### F. Hybrid TCP lane の活用 (TCP 集約の本命レバー)
TCP 主体荷で集約を得るには §1-(6) の lane が直接的。要件:
- クライアント/サーバー双方 `Enabled=true` + `Tcp=stream` (または `auto`: ≥2 パス活性時に lane)。
- サーバー側 `EgressAllow = <実宛先範囲>` (lane が実接続先へ egress するため)。
- **mqvpn コアは libevent 単一イベントループ** (xquic 含めスレッド不使用; hybrid lane のみ
  lwIP 経由で pthread を引き込むが、リレー本体はメイン単一スレッドで走る, §1-(6))。
  lane オーバーヘッドはそのメインスレッドを食い飽和するため、彼らの ECMP 複数インスタンス
  構成でも 1 トンネルは 1 スレッドに収まり実質採用不可。
  ⇒ シングルスレッド架構では §2-G (スケジューラ ピン分散) が唯一現実的な解。

### G. スケジューラのピン分散修正 (raw のまま TCP 集約)
lane の CPU コストを避けたい場合の本質修正: `wlb_pick_pin_path` を「最大 weight の
決め打ち」から**「容量比例ラウンドロビン」**にする。接続間で共有するカウンタで
`path = weighted_rr(global_counter)` とし、連続するフローを A,B,C,A… と振り分ける
(フロー内順序は維持)。到着時刻に関わらず全コネクションが自動で各パスへ散らばる。
⇒ hybrid 不要で raw TCP を全パス分散させる唯一のスケジューラ側解。

### 優先順位
1. **スケジューラ ピン分散修正 (G)** — raw のまま TCP 集約、CPU オーバーヘッド無し (本質解)。
2. **Hybrid TCP lane (F)** — 分散は達成するが、リレー本体がメインの単一 libevent スレッド
   を食い飽和する (§1-(6))。mqvpn コアはシングルスレッドのため実質採用不可。参考のみ。
3. **rate ベース重み (A)** — UDP/非ピンと単一フローのピン先最適化。
4. **重みフロア (B)** — 即効 palliative。
5. **refresh 時ピン再分散 (C)** — ただし §1-(5) 通り現再ピンは無力、G と併用で初めて効く。
6. **溢れ先 = 最低 RTT (E)** — 負荷駆動集約をジッター無しで獲得。
7. **UDP は既に集約 (D)** — ドキュメント化のみ。

## 3. 実測 (本ラボ collapse3: A=30/458 B=42+pareto/400 C=35/450, 合計 1308M)

up.sh で mogami ラボ起動 → bench.sh collapse3 適用 → クライアント(iperf3)→mnet(192.168.100.1)
経由トンネルで計測。ルーター eth1/3/4 の rx を窓で差し引き。
※ 数値はウォームアップ/流れ込みで ±10–20% 変動するが、「TCP は 1 パス偏り・UDP は分散・
hybrid は分散するが低速」の構造は毎回一致。

### 3.1 raw モード (既定, PINNED)
rate-weight パッチ適用済みビルド。

| ケース | eth1(A) | eth3(B) | eth4(C) | TOTAL | 備考 |
|---|---|---|---|---|---|
| TCP -P1 (単一) | 2 | 0 | **221** | ~223 Mbps | **1 パス** に固定 |
| TCP -P20 | 57 | 215 | **403** | **675 Mbps** | 1 パス偏り (eth4 優位) |
| **stagger TCP N=20 (1s ずつ開始)** | 106 | **398** | 136 | **640 Mbps** | **同期(675)と同水準 → ずらしても無意味** |
| UDP -P20 | 393 | 286 | 584 | **1263 Mbps** | 非ピンは 3 パス分散 |

- 単一 TCP = 1 パス上限。speedtest (少数フロー) の 1 パス頭打ちの正体。
- **多フロー (P=20) でも 675M に留まり 1 パス偏り**。さらに**スタガーでも 640M** で変わらず
  → 「多数フロー／到着ずらしで比例分割」は成り立たない (§1-(5))。

### 3.2 hybrid モード (Tcp=stream, 両端)
| ケース | eth1(A) | eth3(B) | eth4(C) | TOTAL | 備考 |
|---|---|---|---|---|---|
| TCP -P1 | 40 | 3 | 35 | **78 Mbps** | **3 パス分散** (1 パス崩壊解消) だが低速 |
| TCP -P20 | 95 | 23 | 73 | **191 Mbps** | 同上、更に低速 |
| UDP -P20 | 700 | 421 | 900 | 2021 Mbps | lane 無影響, 分散維持 |

- TCP は **3 パス全てに分散** (lane が UNPINNED 化した証)。1 パス問題は解消。
- 但し転送効率が raw 以下に転落 (CPU リレー飽和, srvCPU 103%)。CPU 余裕必須。

### 3.3 rate-weight パッチの効果 (§2-A)
`patches/xquic-wlb-rate-weight.patch` 適用ビルドで確認:
- **UDP(非ピン) は完全集約 (~1.3G)**: パケット単位 WRR が rate 重みに忠実 → 3 パス充填。
- **単一 TCP のピン先が B(最高RTT)→A/C(最高rate) に反転**: rate 重みが効いた証。
- **TCP 多フロー集約は和帯域に届かず (~675M)**: `pick_pin` 決定論的単一選択のため
  (§1-(5))。パッチ単体では TCP 集約を解けず、本質解は §2-G (ピン分散修正) または §2-F (lane)。

## 4. 結論

- **UDP/ICMP 主体トラフィック** は構造的に 3 パス全てを使う (崩壊しない)。順序非依存物は UDP で通す。
- **TCP 主体トラフィック** は WLB の PINNED により **フロー数・到着時刻に関わらず 1 パスに収束**
  する。故に本番 speedtest (~少数フロー) が 1 Starlink 相当に頭打ちになるのは構造的。
- これを破るには:
  1. **スケジューラ ピン分散修正 (§2-G)** — raw のまま TCP を全パスへ。フロー発生時の O(1)
     (共有カウンタ+剰余) のみでパケット処理に乗らず、**シングルスレッドでもタダ**の本質解。
  2. **Hybrid TCP lane (`Tcp=stream`)** — 分散は達成されるが、リレー本体がメインの単一
     libevent スレッドを食い飽和し転送効率が落ちる (§1-(6))。彼らの架構では実質採用不可。
- rate-weight パッチは UDP 集約と単一フローの最良パス選択には効くが、TCP 多フロー集約は
  解けない。TCP 集約には上記 1 または 2 が必要。
