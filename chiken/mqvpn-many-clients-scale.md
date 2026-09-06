# 多クライアント規模試験レポート — many-clients.sh による実環境寄り検証

> 実環境 ≒ 70〜140人規模 (`chiken/mqvpn-real-env.md`) を想定した lab 検証の記録。
> 新規 `test/many-clients.sh` の開発・実測、DNS 障害の根本原因特定、blind 再検証を含む。
> lab は `test/up.sh` で再構築した 4VM (mogami-vm / mogami-client / mogami-server / mogami-mnet)。

## 0. 要旨 (結論のみ)

- 70並列 bulk (各1フロー): 合計 3.2–4.1G、欠損フロー 0、3WAN 全使用。上りも 70/70 疎通で合計 1.8G。収容力・CPU・conntrack に余裕
- DNS 多様QNAME欠損の犯人は **ECMP spray と `tun_validate_src` (src/mqvpn_client.c:3428) の組合せ**。
  router 側 mqvpn が TUN-ingress の src≠自 tunnel IP を silent drop。spray 下の src 分散で約 2/3 落下。
  単一隔離・forwarder pin・**OUTPUT MASQUERADE (採用。ECMP 維持のまま多様350/350×2R)** で回復。
  **unbound は無罪**
- 緩和策は OUTPUT MASQUERADE の keeper 管理化 (F0)。pin (F1) は置換え、validation 緩和 (F3) は非推奨
- conntrack は両面とも上限に余裕 (router 8GB→262144、server 2.4GB→65536・平時3.5%)。設定変更不要
- reorder cap はフロー毎隔離で問題なし。少フロー集中は構造的として懸念から除外
- 上記は結論を伏せた blind 再検証 (実測系・コード系の独立2本) でも再現・再発見された
- 残課題: 稀な deep phase (30秒全滅等) は別機構の疑い。EAGAIN burst-drop (R1) が最有力候補

## 1. 背景・手法

### 1.1 bench.sh の乖離

`bench.sh measure/multistream/stagger` は全て mogami-client 単一 IP・単一 MAC 発射。実環境との差:

1. ECMP ハッシュのエントロピー不足 (単一 srcIP では port のみが分散要素)
2. conntrack / NAT テーブルのスケール未検証
3. DHCP (Kea) / ARP / DNS (unbound) の多端末負荷が未測定
4. トラフィック mix が bulk のみ (実態は多数の小フロー＋たまの speedtest)

### 1.2 test/many-clients.sh

client VM 内に N 個の仮想クライアントを生やす。2 モード:

- `alias` (既定): eth0 に secondary IP (172.31.250.1〜、Kea pool 末尾側・衝突事前チェック付)
- `l2`: eth0 上に macvlan を作り、system dhcpcd 経由で Kea から実リース取得＋from-rule policy routing

サブコマンド: `up [N] [--l2]` / `down` / `status` /
`bulk [N] [sec] [down|up]` (per-client 分布＋per-WAN＋両面 conntrack/CPU。up は tx 集計) /
`mix [N] [K] [sec] [dir]` (trickle: ping loss＋rtt＋dns / burst: bulk) /
`dns [N] [Q] [fixed|diverse] [spread_ms]` (2ラウンド＋per-query 遅延分布＋unbound CPU) /
`dhcp-storm [N]` / `netem <ms|hetero|asym|clear>` (bench.sh 同型。up=ルーター egress、下り=ホスト tap egress)

## 2. Lab 環境

- トンネル mqvpn0/1/2 = peer 192.168.0/1/2.1、ECMP `default nhid 2000 (group 1001/1002/1003)`
- base RTT client→mnet 約 2–2.5ms、loss 0%。`netem 10` で RTT 23ms (≒実測 23ms 級) を再現
- ルーター VM: 960MB、conntrack_max=8192、neigh gc 128/512/1024、tcp established 432000s (5日)
- サーバー VM: 963MB (コンテナは `network_mode: host` で VM の netns＝テーブル共用)
- client eth0 は DHCP で 172.16.0.50 (Kea は pool 先頭から逐次払い出し)

## 3. 実測結果

### 3.1 bulk (単一フロー/台)

| 条件 | client合計 | per-client | per-WAN eth1/3/4 | TOTAL(tunnel) |
|---|---|---|---|---|
| 5台 | 2918M | p50=397M, zero=0 | 1668/1382/70M | 3120M |
| 5台 r1–r3 | 4680/3549/3770M | p50=874/476/666M | 主役パスが毎回変動 | 3792–5003M |
| 70台 | 3360M | min28/p50=44/max104M, zero=0 | 1250/933/1422M | 3605M |
| 70台+netem10 | 2031M | min15/p50=23/max139M, zero=0 | 723/419/1039M | 2181M |
| 70台上り+netem10 | 1760M | min16/p50=21/max96M, zero=0 | 564/898/416M (tx) | 1878M |
| l2・10台 | — (計3.4G) | — | 356/863/2213M | 3432M |

- 5台では干上がる WAN が実行ごとに回る (TCP ピン留め＋一斉開始のウォームアップ窓。構造的として除外)
- 70台では 3WAN 全使用。netem10 下では BDP 律速で約 6 割に低下

### 3.2 CPU・conntrack (70台 bulk 時)

| | idle | 負荷中/前後 | 上限 |
|---|---|---|---|
| ルーター conntrack | 12 | 157 (窓中) / 97→243 (前後) | 8192 |
| サーバー conntrack | 66 | 223 (窓中) / 224→282 (前後) | 8192 |
| ルーター CPU | — | 39–40% (窓平均) | 2vCPU |
| サーバー CPU | — | 38% (窓平均、4G 時) | 2vCPU |

- 上限の出所はコード確定: NixOS 側設定は無く、カーネル既定 `nf_conntrack_init_start` の RAM 比例式。
  4GB 超は `htable = 262144` 固定のためルーター 8GB は max=262144。サーバー実測 2.4GB は max=65536・平時 2265 (3.5%)
- 140人需要 (3–14K＋残留) に対し 5 倍以上の余裕。上限 UP 不要

### 3.3 DNS

| 条件 | 成功率 | 備考 |
|---|---|---|
| 固定名 70並列 | 100% (p50=数ms) | cache HIT は常に無事 |
| 多様名 spray (逐次・並列) | 63–86% | 台数・同時/分散・netem によらず発生 |
| 多様名 pin/単一隔離 | 20/20×3、60/60、36/36、24/24 (計156/156) | spray のみ失敗 |
| 多様名＋OUTPUT MASQUERADE (spray維持) | 350/350×2R、60/60 | keeper が自動設置。bulk 回帰なし | **採用 (F0)** |
| 多様名 spray/pin 交互 (同一分数) | spray 28/36・pin 36/36 | phase 説を棄却 |
| fork軽量 70並列×50発 batch (計3500) | 100% | unbound CPUほぼ0。並行でも無罪確定 |
| num-threads 削除 (既定1) | 固定100%・多様86% | スレッド数不問 |
| 実 stub 相当 (+time=5+tries=2) | 85.8% | 90秒窓に均等分散 |

根本原因は §4。warm 時の p95 膨張は client fork storm (lab 2vCPU の 70×約20 fork、loadavg 3–5) と確定。

### 3.4 mix (trickle70＋burst5本)

| netem | burst (5フロー計) | trickle ping loss | trickle rtt avg | trickle dns |
|---|---|---|---|---|
| なし | 3.7–3.8G | p50=0%/max=4% (旧パーサ参考値) | 未取得 | 0/350 |
| 10 (RTT23ms) | 1355M | p50=0%/max=0% | 未取得 | 0/350 |
| hetero (45ms/jitter/loss1%) | 25M (崩壊) | p50=2%/max=8% | p50=103ms/max=106ms | 0/350 |
| asym (up35/down150M) | 271–405M | p50=0%/max=1% | p50=124–186ms/max=294–466ms (base 27ms) | 0/350 |

- hetero 下では bulk TCP がほぼ死ぬ一方 DNS は無事 (reinjection が吸収)
- asym 下では loss なし・rtt 4–10 倍膨張。遅延の巻き添えは明確に存在

### 3.5 dhcp-storm

- l2・10台: release 10/10 → renew 10/10、約 7 秒、kea エラー 0
- l2・70台: release 62/70 → renew 70/70、約 21 秒、kea エラー 0

## 4. 根本原因の特定 — DNS 多様QNAME欠損

### 4.1 部品特定: `tun_validate_src` (src/mqvpn_client.c:3428–3451)

router 側 mqvpn client は TUN-ingress パケットの IPv4 src が自トンネルの assigned_ip と
完全一致しないものを **silent drop** する (`LOG_D "tun drop: IPv4 src mismatch"` のみ、カウンタなし):

- ECMP spray 下では kernel の src 選択がトンネルと独立に .0/.1/.2 へ分散する
  (router capture・server conntrack で実証) ため、約 2/3 が不一致で落ちる
- 実測 (88 sends→21–28 到達 ≒ 24–32% 生存) と一致。定量モデル:
  attempt 生存 ~1/3 × 実効再送 ~3–4 回 (SERVFAIL@1.7s・client timeout で打切り) →
  P(失敗) ≒ (2/3)^3.5 ≒ 20–25% ≒ 観測 15–35%
- pin/単一では src＝out-dev addr に確定し常時一致 → 156/156 無敗
- NAT済み LAN トラフィックは MASQUERADE で out-dev addr になるため常時一致 → 無傷
- STATUS の tcp_dropped/dgram_lost が 0 のままなのは、この drop がどのカウンタにも載らないため。
  cold-name 上流 tail との複合で SERVFAIL・timeout として観測される

### 4.2 完全因果連鎖 (last mileまで特定。カーネル＋unbound両ソース読解済み)

送信元IPの決まり方 (net/ipv4/{fib_semantics.c:2223,route.c:2894}、kernel 7.2):

- fresh lookup (saddr=0): ECMP member をハッシュ選択 → `fib_result_prefsrc` で
  **当該 member の dev addr** を返す (per-nexthop `nh_saddr`＋genid 管理)。`ip route get` が
  常に一致ペアを返すのはこの世界。決定論的で矛盾なし
- unbound は UDP を **CONNECTED socket** で出し (`ss` で `192.168.0.2:xxxxx → 1.1.1.1:53` を捕捉、
  `outnet->udp_connect` 経由)、pool で再利用する。connect 時に上記で一致ペアが確定し socket＋dst に cache
- keeper が **3秒毎に ECMP route を replace** するため cached dst が失効し、pool 再利用時に再解決が走る。
  再解決では **saddr が保持されたまま** (`fib_select_path` の `if (!fl4->saddr)` が偽で再選択スキップ)。
  ECMP 再ハッシュは保持 saddr を入力に含むため別 member に落ち得る → src≠member で **TUN ingress drop**
- 定量一致: 初回 (fresh) は一致。 keeper 周期を跨いだ再利用が約 2/3 で不一致 →
  70並列×5逐次で全体 ~63–68% ≒ 初回観測 62.9%。SERVFAIL (~1.7s で unbound が諦め) と
  timeout (client 打切り) の内訳とも整合。churn 停止実験では SERVFAIL が消滅し timeout のみ残存
  (不一致が消え slow tail のみが残ることの裏付け)
- MASQUERADE が bulletproof な理由: POSTROUTING で **毎パケット現 out-dev addr に書換え** のため、
  socket の新旧・keeper 周期・ECMP 分散の全てを吸収。pin は再解決先単一のため有効だが pool 過渡に依存
- 残り未特定分: keeper replace による dst 失効の厳密なタイミング (rt_genid bump の標準 semantics
  として扱い直接 trace 未実施)、unbound pool の排水タイミング (idle 後 `ss` 空振りで確認)。
  運用判断への影響なし。なお keeper 冪等化 (変化時のみ書換え) は dst 失効自体を減らせる別解だが、
  MASQUERADE で包含されるため見送り (記録のみ)

### 4.3 除外リスト (全て証拠付き)

- unbound 容量・スレッド・validation: CPU 0–3%、requestlist exceeded 0・jostled 0 (停止時 stats)、
  validation failure 0、cached 3500 並行 100%、1/4 スレッド同率
- forwarder (直叩き各 6/6 正常)、router kernel UDP (InErrors/RcvbufErrors=0)、conntrack (drop=0)、
  firewall DROP (0)、keeper flap (0件)、WAN 直抜け (host bridge で port 53 ゼロ)、時刻同期
- ハイジャック説: DNSSEC validation success のため否定 (検証で覆した)
- warm p95 膨張: client fork storm (本番 140 台実機では出ない)
- WLB スケジューラ: drop しない (遅延のみ)。reorder cap はフロー毎隔離で問題なし (§6 の旧懸念を解消)
- ECMP メンバー単体: 20/20×3 で全て無罪

### 4.3 blind 再検証 (結論を伏せた独立 2 本。両方とも同一結論に到達)

- 実測系: 多様名 58–100% (phase 変動)・固定名 100% を再現。`ping -I` による src/dev 対応試験で
  「src≠dev で 100%死・一致で 100%疎通」の完全反転を確認 (pin 切替で反転も再現)。緩和策 (/32 pin) も
  独立に発見・検証 (40/40、300/300)。lab はクリーンに復帰、repo 無改変を確認
- コード系: TUN ingress の src 照合 (`tun_validate_src`) を含む silent-drop 条件を ranked list (R1–R12)
  として列挙。特に R1 (QUIC backpressure EAGAIN で in-hand パケット破棄＋TUN 停止、カウンタなし)、
  R4/R5 (reorder 統計は `get_reorder_stats` RPC のみ・STATUS に出ない)、
  server 側 `forward_inner_ip` の src 照合 (LOG_W) が新規知見

## 5. 緩和策・運用提案

推奨順 (F1 pin は MASQUERADE に置換え — 下記):

- **F0 (採用): router-local → tunnel の SNAT 確保** (`configuration.nix` keeper 内で
  `iptables -t nat -A nixos-nat-post -o "mqvpn+" -j MASQUERADE` を毎ループ ensure)。
  out-dev addr に確定し `tun_validate_src` に常時一致。**ECMP spray 維持**・トンネル IP 変更に追従・
  LAN 側は既存 mark 規則と同値で無害・flush されても keeper が復旧。lab 検証:
  keeper が自動設置、diverse 70×5 両ラウンド **100% (350/350, timeout 0)**、
  bulk 70 (3146M, zero=0) で回帰なし。対象が DNS に限らず router-local 全般 (将来の NTP 等) のため
  pin より優れる。pin の単一障害点 caveat も消滅
- F1 (forwarder /32 pin): 実証済み (156/156) だが F0 に置換えのため不採用。keeper コードから削除済み
- F2 (router-local 全般の単一トンネル化): F0 で目的達成のため不要に。policy routing の runtime 実験は
  lab 安定性懸念 (下記) のため凍結のまま
- F3 (validation 緩和): spoofing 防止境界のため非推奨のまま
- F2: router-local 全般の単一トンネル化 (F1 の一般化。lab 安定性懸念で runtime 実験を凍結中のため未再試験)
- F3: mqvpn の validation 緩和は**非推奨** (spoofing 防止境界。F1/F2 で同等効果のためパッチ化しない)
- unbound 自体の tuning (threads 等) は効かないことを確認済み。cache 側 (min-ttl 等) は cold 分率を下げる程度

## 6. 実環境への示唆 (更新版)

1. conntrack: 上限に余裕あり (§3.2)。設定変更不要
2. DNS: §4 の通り。F1 でほぼ消せる見込み。warm cache＋実 stub では散発報告レベル
3. 巻き添え: 遅延膨張は確定 (§3.4)、欠損は条件次第
4. 非問題: ECMP 均等化、`max_clients=64` (対ルーター数)、Kea、neigh、NAT port、サーバー CPU、reorder

## 7. 残課題

- 稀な deep phase (30秒全滅・corr 23% 等) は tun_validate_src では説明が付かない別件。
  ECMP・keeper・全カウンタ正常下で発生。新最有力候補は **R1 EAGAIN burst-drop**
  (bursty 時に in-hand 破棄＋TUN 停止、カウンタなし)。`get_reorder_stats`＋STATUS `tun_readable` の
  同時採取、または mqvpn 計装が次の手
- hetero の rate 付き地形での many-clients メニューは未実施
- 上り mix 未測定 (bulk 上りは実測済み)
- lab 安定性注意: investigation 中に router VM が応答不能化 (policy routing 操作との時間相関あり。
  qemu 残存ハング・全 VM 消失も各1回)。dmesg/oomd/journal に痕跡なし。runtime の policy 実験は凍結。
  以降の検証は keeper 管理の正規 route のみで行うこと
- `ip route get ... sport` sweep (read-only): 単発照会では dev＝src が常時一致。
  しかし live では同一トンネルから別 src (.2.2 と .0.2 が共に mqvpn1 経由) が観測される。
  すなわち照会経路と data path の src 選択が一致しない。厳密なカーネル内関数までは未特定
  (member 選択と src 選択が別関数・別 seed の可能性が濃厚) が、運用上は MASQUERADE が
  結果を確定させるため不問
- unbound `outgoing-interface: 192.168.0.2` 強制＋spray: 33/45 (73%)。
  src 固定でも ECMP が member を分散させるため約 1/3 の attempt のみ一致、再送で畳み込んで 73%。
  match 確率モデルの直接裏付け。server conntrack で src 全件 .0.2 を確認 (bind 有効の証拠)
- `status` の kea lease 数はファイル glob 頼み (best-effort)
