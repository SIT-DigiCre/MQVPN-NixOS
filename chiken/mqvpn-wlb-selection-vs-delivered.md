# mqvpn WLB 選択 vs 配送 — 「帯域が使い切られない」はスケジューラではない

> 更新: 2026-08-28
> 対象ビルド: mqvpn v0.16.1 + 全 WLB パッチ + `xquic-wlb-selcount.patch` (計測用)。
> ラボ (MQVPN-NixOS test/) 計測。ルーター側で mqvpn を手動起動 (selcount ビルド) し、
> `collapse3` netem (eth1=458M/30ms, eth3=400M-pareto/42ms, eth4=450M/35ms) を適用。

## 問い

「全パスの帯域が使い切られない」原因は (A) スケジューラの重み選択(weight) が偏っているか、
(B) 輻輳制御(CC)/フロー数/CPU による配送限界か。本検証は (A) を決定的に切り分ける。

## 手法

- `xquic-wlb-selcount.patch`: WLB スケジューラの `xqc_wlb_scheduler_get_path` が**各パケット送信時**
  (pinned 高速パス / recovery / single-path / WRR の全 return) に `sel_bytes`/`sel_pkts` を加算し、
  `/tmp/mqvpn_wlb_sel_<pid>.log` に 1Hz で累積値を書き出す (意図した割り当て = selection)。
  - 初版は WRR 選択ブランチのみ計測していたが、実トラフィックの大半は pinned 高速パス
    (line 911 の `return path;`) を通り 1 パケット/14s しか拾えなかった。全 return で計測するよう修正。
- 配送(delivered) はサーバー側 exporter の `mqvpn_path_bytes_rx_total{path_id}` (uplink では
  ルーターが各パスに送ったバイト = 配送) の窓差分を使用。
  - **注意: mqvpn の `STATUS` ログの `tx=` はリアルタイム累積バイトではない** (426Mbps 流入中も
    +120B しか動かず)。delivered には exporter メトリクスを使うこと。
  - また bench.sh の per-WAN `rx_bytes` 計測は uplink で RX(ACK) を測っており不正。uplink 比較は
    iperf SUM か exporter を使うこと。
- 手順: router VM (`mogami-vm`) を本リポジトリから再ビルド・再起動し、`mqvpn-0/1` を systemd
  service として selcount ビルドで自動起動 → collapse3 netem → クライアントから uplink iperf
  (-P 20, 14s) → 窓前後で selection と delivered を差分。(手動起動は不要)

## 結果 (collapse3, uplink, 単一インスタンス mqvpn-0, 同一窓)

| path | 容量 / srtt | **selection %** (sel_bytes Δ) | **delivered %** (rx_total Δ) |
|------|-------------|-------------------------------|-------------------------------|
| eth1 (`path0`) | 458M / ~30ms | **55.38%** | **55.48%** |
| eth3 (`path1`) | 400M-pareto / ~78ms | **19.77%** | **19.69%** |
| eth4 (`path2`) | 450M / ~35ms | **24.85%** | **24.82%** |

選択と配送が各パスで **0.1% 未満**で一致 (合計 ~700Mbps)。
(注: 2 インスタンス同時だと server 側 `rx_total` が per-connection の path_id を集約し
path 対応が曖昧になるため、単一インスタンスで計測。複数インスタンスでも各接続ごとには選択≈配送。)

## 推論

1. **スケジューラの重み選択バグではない。** 選択は容量/RTT 考慮で比例しており、WLB が X% 送れば
   X% 届く。selection と delivered の乖離(=CC/天井による未充填) は**観測されない**。
2. 本実験で証明したのは「選択≈配送」、すなわち**スケジューラ起因の未充填ではない**という一点のみ。
   総スループット天井の「正体」は本実験単体では未証明。以下は先行実験との整合:
   - **フロー数スイープは棄却**: -P 1..40 で TOTAL が ~550–760Mbps に頭打ち
     (`mqvpn-wlb-distribution-and-bandwidth.md` 系)。iperf は `-P 20` = 20 本の TCP ストリームを
     張っているので「単一 TCP コネクション」説は当たらず、トンネル内フロー数では説明できない。
   - **`reinjection=off` は天井を上げず、downlink 配分は悪化** (474M/Jain 0.50 vs deadline 672–856/Jain 0.91)。
     再注入処理を省いても開かない ⇒ **CPU/再注入コストが天井**説はデータと矛盾し棄却。
     さらに mqvpn は 2 インスタンスで 2 コアに分散される設計なので、単純なシングルスレッド天井説も弱い。
   - よって初期草稿で書いた「単一コネクション/CC/シングルスレッド」は**根拠不十分として撤回**。
3. 天井の候補と、virtio / CPU 説の除外調査 (router VM `mogami-vm`, `-smp 2`):
   - **(a) マルチパス tunnels 上の BBR 集約挙動** (各パス BBR が保守的で、容量和に届かない) が最有力。
     クリーン単一インスタンス計測では各パスとも netem 容量上限に届いていない
     (eth1≈385M/458M, eth3≈140M/400M, eth4≈175M/450M)。つまり BBR が各パスを使い切っていない。
   - **(b) virtio 単一キュー上限説 → 棄却。** router の WAN NIC は `ethtool -l` で `Combined=1`
     (単一キュー、`Pre-set max=1` なので `ethtool -L` で増やせず)。しかしトンネルを経ない
     **生 virtio スループットを計測**: client → server(192.168.50.2, 同一ホスト内ブリッジ) で
     **19–28 Gbps** (20並列 19.3G / 単流 28G)。単一キューでも数十 Gbps 出るので、
     トンネルの ~700Mbps 頭打ちは virtio/ホスト QEMU バックエンドでは説明できない。
   - **(c) CPU / xquic シングルスレッド説 → 棄却。** 飽和時(トンネル ~700Mbps)に router の
     両 vCPU を `/proc/stat` で採取: いずれも **~84% アイドル**。xquic が 1 インスタンス=1 スレッド
     でも CPU 余裕は十分で、シングルスレッドが天井ではない。
   - よって天井の正体は **(a) BBR のマルチパス集約挙動** に絞られる。対処はスケジューラではなく
     CC(各パス BBR の容量利用向上) またはトンネル複数化。
4. 唯一の実スキュー: **eth3 が ~17–20% (容量比率 ~30% に対し)**。これは `xquic-wlb-rtt-favor.patch` が
   78ms パスを意図的にやや下げるもの。selection と delivered が一致するので崩壊ではなく意図的チューニング。
   低RTT優遇を強めると eth3 がさらに枯渇するだけ。

## 結論

「全帯域が使い切られない」の原因は **WLB スケジューラの選択ではない** (選択は比例配分され、実測も追従、
クリーン単一インスタンスで selection 55.4/19.7/24.8% vs delivered 55.5/19.7/24.8%)。
対処すべきは**トンネル総スループットの天井**で、その正体は **BBR のマルチパス集約挙動**。
virtio 単一キュー説(生計測 19–28Gbps で棄却) と CPU/シングルスレッド説(飽和時も vCPU 84% アイドルで棄却)
はいずれも除外済み。次は **各パス BBR の容量利用を上げる CC チューニング** か、**トンネル複数化** による
総スループットの線形化。

## 本番確認 (実 Starlink 環境, 2026-08-28)

router=172.16.0.1 (NixOS, mqvpn 0.16.1, mqvpn-0/1), server=<VPS, Ubuntu, Docker
mqvpn-server-0/1 自前ビルド 0.16.1)。3×Starlink (Flat/Move/Mini) を enp1s0f0 / enp1s0f2 /
enp1s0f3 経由で収容 (enp1s0f1 他は DOWN)。enp1s0f2/enp1s0f3 の gw は共に 192.168.1.1 だが
**MAC が別 (=別 Starlink ルータ、双方デフォルト IP 被り)**。

### 物理回線容量 (各 WAN 強制出口で計測: VPS iperf に対し `-B <wan-ip>` + ポリシールートで出口固定)
| WAN | iface | 下り (mean, n=5) | 上り (mean, n=5) |
|-----|-------|------------------|------------------|
| A | enp1s0f0 (gw 192.168.4.1) | 217 Mbps (67–277) | 36 Mbps (22–51) |
| B | enp1s0f2 (gw 192.168.1.1, MAC d8:01:a1) | 175 Mbps (68–223) | 37 Mbps (34–44) |
| C | enp1s0f3 (gw 192.168.1.1, MAC 34:fb:a5) | 107 Mbps (n=2, 80–133) | 20 Mbps (n=3, 5–37) |

平均下り合計≈499 Mbps (A217+B175+C107, ただし変動大・Cはn=2)。mqvpn0 単体の実測下り 366 Mbps はこのレンジ内 ⇒ **VPN は 3 回線をソフト天井なしに集約**。
(各値は N=5 強制出口計測の平均(範囲付き); Starlink は時刻/天候で容量が大きく変動。C は後半の試行で欠測(一時断?)多く n が小さい)

### UDP (QUIC 基盤) の挙動 — Starlink は UDP を猛烈に drop
各 WAN を `-B <wan-ip>` 強制出口で `-b 1000M` UDP 洪水した結果:

| WAN | UDP上り(mean, n=5) | 上りロス | UDP下り(mean, n=3) | 下りロス |
|-----|---------------------|----------|---------------------|----------|
| A | 44 Mbps (5–73) | 92–99% | 347 Mbps | 63–67% |
| B | 59 Mbps (49–71) | 93–95% | 386 Mbps | 56–69% |
| C | 40 Mbps (n=2, 37–43) | 96% | 189 Mbps (n=2) | 76–86% |

生UDPを1Gbps流すと上り9割/下り6–9割捨てられる。**下りの方が生き残りが多い** (Starlink 下り余裕)。
単純洪水では UDP 容量は使い物にならず、mqvpn(QUIC=UDP) の実スループットは
**QUIC 自身の BBR が UDP レートを絞ってロスを避ける**ことで決まる (TCP 並みに収束すると予想)。
「UDP だと Starlink が落とす」は VPN の CC チューニングを語る上で重要な基盤特性。
(正確な UDP低ロス容量が欲しい場合は `-b` 50/100/200M 段階スイープが必要。洪水の「生き残り」は容量ではなく溢れ分)

### スキュー検証 (selection ≈ delivered, 本番でも)
20s 飽和 downlink iperf 中の窓差分 (server 側 selcount vs `mqvpn_path_bytes_tx_total`)：

| path_id | selection | delivered | sel% | deliv% |
|---------|-----------|-----------|------|--------|
| 0 | 64.8 MB | 65.6 MB | 15.3% | 15.3% |
| 1 | 183.1 MB | 185.2 MB | 43.3% | 43.3% |
| 3 | 174.8 MB | 176.8 MB | 41.4% | 41.4% |

**各パスで selection と delivered が <1% で一致** → ラボ同様スケジューラ崩壊(skew) なし。
選択配分は物理容量にほぼ比例 (最小回線 C も ~15% を獲得、ゼロ枯渇ではない)。
path_id→WAN の厳密マッピングは取っていないが、スキュー有無の結論は path 順序に依らず成立。

### 結び (本番)
「帯域が使い切られない」の原因は**スケジューラ選択ではない**(選択=配送かつ容量比例)。
実環境では単に**最小回線 C(Mini, 70.8Mbps) の物理容量**が律速し、VPN は 3 回線をきちんと
集約している。対処が必要なら CC(各パス BBR の容量利用向上) かトンネル複数化であり、
スケジューラ重みの修正ではない。

## 補足 (再現)

- パッチ: `patches/xquic-wlb-selcount.patch` (`pkgs/mqvpn-src.nix` に登録済。故に `mogami-vm` の
  `mqvpn-dbg.nix` 経由で service バイナリに含まれる)。
- ラボ展開(正規): `nix build path:.#nixosConfigurations.mogami-vm.config.system.build.vm
  --out-link /tmp/result-mogami` で router VM を再ビルドし再起動。`mqvpn-0/1` は systemd service
  として自動起動し `/tmp/mqvpn_wlb_sel_<pid>.log` を書く (手動起動は不要)。
  netem 適用: `sudo tc qdisc add dev eth1 root netem delay 30ms rate 458mbit`、
  eth3 は `sudo tc qdisc add dev eth3 root netem delay 42ms 5ms distribution pareto rate 400mbit`、
  eth4 は `sudo tc qdisc add dev eth4 root netem delay 35ms rate 450mbit`。
- 配送: サーバー `curl localhost:9091/metrics | grep mqvpn_path_bytes_rx_total` (uplink) /
  `mqvpn_path_bytes_tx_total` (downlink)。
