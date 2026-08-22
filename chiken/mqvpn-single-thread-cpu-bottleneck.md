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
  (jiffies/s, 100 = 1 コア飽和)。perf: `perf record -F 99 -e cpu-clock -g` (PMU 不要)。
- ツール: `./test/bench.sh latency|hetero|multistream|profile|clean`
  (設定変更は nix ファイル編集 + 再ビルド。perf はサーバー systemPackages に常駐化済み)。

## 現状の計測結果 (2 パッチ + reinjection=deadline, 50ms, 下り)

| 要求 | 受信 | ロス | サーバー CPU | ルーター CPU |
|---|---|---|---|---|
| 600M | 578-587 Mbps | 2.2-3.7% | 49-51 | 43-53 |
| 800M | 741-764 Mbps | 4.5-7.4% | 57-58 | 51-60 |
| 1000M | 882-992 Mbps | 0.8-12% | 64-66 | 58-65 |
| 1200M | 1,069 Mbps | 11% | 72 | 66 |
| 1500M | 1,238-1,292 Mbps | 14-17% | 81-83 | 81 |
| 2500M | 1,524-1,690 Mbps | 32-39% | 97-100 | 96-98 |

### ホットスポット (perf, 下り, 50ms, 1000M 要求時)

| self% | 関数 |
|---|---|
| 11.9% | `xqc_conn_reinject_unack_packets` |
| 4.3% | `xqc_deadline_reinj_can_reinject` |
| 3.4% | `mqvpn_server_on_tun_packet` |
| 3.0% | `xqc_send_ctl_on_ack_received` |

## 要因と効果の分解

### 600 Mbps の壁の正体

- mqvpn の送信側単スレッドが pulse: wlb 重み計算 + BBR pacing + ACK/再送処理は
  RTT に比例して増加。RTT≈0 のラボでは 1.5 Gbps でも CPU ~55-65%。
- RTT 50ms では reinjection=deadline の **unacked 走査** (在庫量 ∝ RTT × レート) が
  支配コストとなり単スレッド 100% で頭打ち。

### パッチの効果 (deadline のまま)

| 構成 | 800M 受信/ロス | サーバー CPU | 上限 (50ms) |
|---|---|---|---|
| パッチなし | 707 / 12% | 103 飽和 | ~780 Mbps |
| scan のみ | 749 / 6.4% | 103 飽和 | ~1.1 Gbps |
| **scan + rate-limit** | 764 / 4.5% | **58** | **~1.7 Gbps** |

- rate-limit (2ms スキャン間引き) が CPU 飽和打破の主役 (800M で 103→58、
  上限 1.1G→1.7G)。scan (1 回あたりコスト削減) は膝効率・上限を各々改善。
  rate-limit 単独は scan 前提のため適用不能 (差分法で評価)。
- スキャン間隔感度 (XQC_REINJ_SCAN_INTERVAL_US): 800M は 2000 が最良 (CPU 58)、
  上限重視なら 1000 が有利 (2500M で 1,819 Mbps)。デフォルト 2000u を推奨。

### reinjection=off の効果 (パッチとは独立の次元)

- off 時はスキャン自体が呼ばれない (mp_enable_reinjection ガード) ため、
  パッチのコードは不活性。効果はパッチ有無と無関係。

| 要求 (両端 off) | 受信 / ロス | サーバー CPU | ルーター CPU |
|---|---|---|---|
| 800M | 798 / 0.25% | 63 | 73 |
| 1500M | 1,494 / 0.4% | 56 | 61 |
| 2500M | 2,403 / 3.9% | 70 | 81 |
| 4000M | 2,962 / 26% | 82 | 75 |

- 1000M 要求時の perf は完全に分散 (ack 4.8% / tun 4.4% / AES-GCM 4.0%)。
- 参考: パッチなし + サーバーのみ off では上限 ~1.6-1.9 G (両端 off との差は
  「どこを off にしたか」の違い)。

### 上り方向・下流並列

- 上り (ルーター=送信側), 2 パッチ + deadline, 50ms: 500M で送信側 CPU 88-95 → 34。
  上限 ~1.3 Gbps 級。
- 下流 10 クライアント並列 (TCP, 50ms): 合計 ~566 Mbps、サーバー CPU ~46% で余裕
  (パッチなしなら同条件で飽和していた)。

## ロスの機構

- ロスは「送信要求レート − トンネル実効容量」の超過分。2500M 要求・25% ロス時の分解:

| 箇所 | 割合 |
|---|---|
| サーバー側 tun (mqvpn0, qlen 500 ≈ 0.7MB) TX drop | ~62% |
| クライアント側カーネル UDP | ~38% |
| トンネル内 / netem | 0% |

- 送信アプリ (UDP) は輻輳制御を持たず、tun の微小キューは吸収不能。
  単スレッド mqvpn の読出し容量 < 投入 → **カーネルのキューで溢れる** (NET_XMIT_DROP)。
  qlen を上げても遅延が増えるだけで抜本解決にならない。

## 不均質 + ロス条件 (45/45/75/75/15ms, loss 0.2-1%)

| 構成 | 1000M 結果 (複数試行) |
|---|---|
| パッチ + reinj=off | 993-996 Mbps / 0.4-0.7% |
| パッチ + deadline | 997-998 Mbps / 0.2-0.3% |
| パッチなし + deadline | 983-995 Mbps / 0.5-1.7% |


## 推論 (実運用への示唆)

1. **600 Mbps の壁は reinjection=deadline の unacked 走査コスト**。RTT の大きい環境
   ほど在庫が増えて単スレッドを消費する。
2. **scan + rate-limit パッチで、実ロス回復を保ったまま ~1.7 Gbps 級** (CPU 半分)。
   実環境での適用推奨。
3. 上限を最優先するなら reinjection=off (~3 Gbps 級) だが、実ロス時の回復を失う。
   実回線 (Starlink 等) のロス率次第で A/B 判断。
4. さらに必要な帯域があれば、server 2 インスタンス化 (2 vCPU 活用) か、
   scheduler=minrtt / cc=cubic との併用 (CPU -15% / -10% 計測済み)。

## 残課題

- 上り方向 + reinjection=off の計測。
- 実環境 (Ryzen 9 7900 2vCPU, 7 パス) での A/B 検証。
- スキャン間隔 1000u vs 2000u の膝特性の詳細確認。
