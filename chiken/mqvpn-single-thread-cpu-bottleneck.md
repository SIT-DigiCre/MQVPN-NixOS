# mqvpn サーバー単スレッド CPU 飽和 (600Mbps の壁)

> 更新: 2026-08-22
> 対象ビルド: mqvpn v0.16.0 + max-paths + xquic-reinjection-scan + xquic-reinjection-rate-limit,
> RelWithDebInfo / シンボル付き。ラボ (MQVPN-NixOS test/) 計測。

## 現象 (実環境)

- サーバー: Ryzen 9 7900 (2 vCPU), 7 パス (Starlink×3 / モバイル×3 / eduroam×1), hybrid 無効
- speedtest (下り) で **~600 Mbps 付近でサーバーの単スレッド CPU が 100%** になり頭打ち。
- hybrid (TCP lane) 有効時は ~300 Mbps に低下 (ACK エミュレーションが送信側コストを上積み)。

## 計測環境・方法

- 3 VM (KVM): ルーター (4vCPU) / サーバー (4vCPU) / 下流クライアント。
  クライアント → トンネル (192.168.0.0/24) → サーバー → internet。
- netem をルーター VM 内の WAN NIC (eth2/4-7) に適用 (片道の送信側遅延、limit 100000)。
- iperf3 UDP 下り (サーバー=送信側), 15 秒。CPU は `/proc/<pid>/stat` 1 秒サンプル
  (jiffies/s, 100 = 1 コア飽和)。
- perf: `perf record -F 99 -e cpu-clock -g` (PMU 不要)。
- ツール: `./test/bench.sh latency|hetero|multistream|profile|clean`
  (netem 適用 / CPU サンプリング / perf を自動化。設定変更は nix ファイル編集で行う)。

## 計測結果 (50ms RTT, 下り, reinjection=deadline)

| 要求 | 受信 | ロス | サーバー CPU | ルーター CPU |
|---|---|---|---|---|
| 600M | 578 Mbps | 3.7% | 51 | 53 |
| 800M | 764 Mbps | 4.5% | 58 | 60 |
| 1000M | 922 Mbps | 7.8% | 66 | 65 |
| 1200M | 1,095 Mbps | 8.7% | 73 | 73 |
| 1500M | 1,238 Mbps | 17% | 83 | 81 |
| 2000M | 1,351 Mbps | 32% | 94 | 93 |
| 2500M | 1,690 Mbps | 32% | 97 | 98 |

### ホットスポット (perf, 下り, 50ms, 1000M 要求時)

| Overhead (self) | 関数 |
|---|---|
| 23.2% | `xqc_conn_reinject_unack_packets` |
| 6.4% | `xqc_deadline_reinj_can_reinject` |
| 3.5% | `mqvpn_server_on_tun_packet` |
| 3.3% | `aes_gcm_enc_update_vaes_avx2` |

### 比較: パッチなしビルド (同一条件)

| 要求 | 受信 / ロス | サーバー CPU | reinject self% |
|---|---|---|---|
| 600M | 586 / 2.3% | 102 | — |
| 800M | 707 / 12% | 103 | — |
| 1000M | 781 / 22% | 103 | 62.0% + 18.7% |

## ロスの分解 (2500M 要求・20 秒・受信 1,868 Mbps / 25% ロス時)

iperf 計測ロス 1,187,657 パケットの発生箇所 (カウンタ差分):

| 箇所 | 差分 | 割合 |
|---|---|---|
| サーバー側 tun (mqvpn0) TX drop | +736,251 | ~62% |
| クライアント側カーネル UDP InErrors | +460,433 | ~38% |
| ルーター側 mqvpn0 rx/tx drop | 0 | 0% |
| netem キュー | 0 | 0% |

- **ロスは「送信要求レート − トンネル実効容量」の超過分**が:
  1. サーバーの tun→mqvpn 投入時にキュー溢れで drop (~62%)
  2. クライアントの UDP スタックで drop (~38%, RcvbufErrors≈0 なのでアプリバッファ不足ではない)
- トンネル内部・回線エミュレーション側は drop ゼロ (送信側パイプラインで全て吸収)。
- トンネル実効容量以下を要求すればほぼロスなし。

### なぜ「カーネルのキューから溢れる」のか

- 送信アプリ (UDP) は輻輳制御を持たず、要求レートを減速しない (TCP なら sndbuf 詰まりで自己減速)。
- サーバーの tun (mqvpn0) は **`qlen 500` (≈0.7MB, fq_codel)** と微小なキューしか持たない。
- mqvpn は単スレッド・CPU 飽和 (~98%) で tun の読出しが投入に追いつかない。
- → 入り口 (アプリ→カーネル→tun) は無制御、出口 (QUIC 送信) は単スレッド実効上限つき
  という構造のため、出口が詰まると入り口の小さなキューで `mqvpn0 tx_dropped`
  (NET_XMIT_DROP) になる。**qlen を上げてもバッファが増えるだけで抜本解決にならない**。

### 参考: パッチなしビルド + reinjection=off (50ms, 下り)

reinjection=off は設定変更で nix ファイルを編集して有効化 (ロス回復機能は失う)。

| 要求 | 受信 / ロス | サーバー CPU | ルーター CPU |
|---|---|---|---|
| 800M | 737-763 / 4.6-8% | ~40-51% | — |
| 1500M | 1,160-1,219 / 19% | 65-67% | — |
| 2500M (ピーク付近) | ~1,560-1,960 / 22-37% | 67-86% | 86-117% 飽和 |

- 送信側の reinjection コストを消すと上限は ~2 Gbps 級 (パッチ無し + deadline の
  ~780 Mbps から開く)。ただし次の壁はクライアント (受信側) の単スレッド。
- 「パッチあり + reinjection=off」の組み合わせは未計測。

## 推論

1. **600 Mbps の壁の正体は reinjection=deadline の unacked 走査コスト**。
   RTT が大きい環境 (実回線 10-100ms) ほど在庫 (RTT×レート) が増えて単スレッドを消費する。
2. **scan + rate-limit パッチの効果**: 同帯域でサーバー CPU を約半分に削減
   (103% → 58% @ 800M)。上限は ~780 Mbps → ~1.7 Gbps 級 (2 倍超) に拡大。
   reinjection の占有率も 62% → 23% に低減し、ロスも膝で改善 (12% → 4.5%)。
3. 2500M 要求ではサーバー・ルーターの両端が ~97-98% で飽和 — 次の壁は
   クライアント側 (受信側) の単スレッドが支配的になりつつある。
4. 実運用への推奨:
   - 本パッチ (scan + rate-limit) の適用で、実環境でも帯域と CPU の余裕が
     ~2 倍以上になる見込み (実回線で A/B 検証推奨)。
   - さらに必要なら server 2 インスタンス化 (2 vCPU 活用) や
     scheduler=minrtt / cc=cubic (CPU -15% / -10% 計測済み) の併用。

## 残課題

- 不均質 (RTT 15-75ms 混在) + ロス 0.2-1% でトンネルがほぼ停止する条件の詳細化
  (パッチ適用で改善するか未検証)。
- idle/dgram モードの CPU 特性。
- 上り方向 (ルーター=送信側) のパッチ効果。
