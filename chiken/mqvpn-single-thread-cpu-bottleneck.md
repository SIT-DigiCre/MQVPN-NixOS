# mqvpn サーバー単スレッド CPU 飽和 (600Mbps の壁)

> 更新: 2026-08-22
> 対象ビルド: mqvpn v0.16.0 + max-paths パッチ (**reinjection パッチなし**),
> RelWithDebInfo / シンボル付き。ラボ (MQVPN-NixOS test/) 計測。

## 現象 (実環境)

- サーバー: Ryzen 9 7900 (2 vCPU), 7 パス (Starlink×3 / モバイル×3 / eduroam×1), hybrid 無効
- speedtest (下り) で **~600 Mbps 付近でサーバーの単スレッド CPU が 100%** になり頭打ち。
- hybrid (TCP lane) 有効時は ~300 Mbps に低下 (ACK エミュレーションが送信側コストを上積み)。

## 計測環境・方法

- 3 VM (KVM): ルーター (4vCPU) / サーバー (4vCPU) / 下流クライアント。
  クライアント → トンネル (192.168.0.0/24) → サーバー → internet。
- netem をルーター VM 内の WAN NIC (eth2/4-7) に適用 (片道の送信側遅延、limit 100000)。
- iperf3 UDP を up/down 両方向、15 秒。CPU は `/proc/<pid>/stat` 1 秒サンプル
  (jiffies/s, 100 = 1 コア飽和)。
- perf: `perf record -F 99 -e cpu-clock -g` (PMU 不要)。
- ツール: `./test/bench.sh latency|hetero|multistream|profile|clean`
  (netem 適用 / CPU サンプリング / perf を自動化。設定変更は nix ファイル編集で行う)。

## 現状 (reinjection=deadline のまま) の計測結果

### 送信側 CPU は RTT に依存して増加する

| 方向 | RTT | 要求/受信 | サーバー CPU | ルーター CPU |
|---|---|---|---|---|
| 下り (サーバー=送信側) | ~0ms | 1500M 要求 → 1497 Mbps | ~55-65% | — |
| 下り | 50ms | 600M → 586 (2.3% loss) | 102 | 48 |
| 下り | 50ms | 800M → 707 (12%) | 103 | 49 |
| 下り | 50ms | 1000M → 781 (22%) | 103 | 56 |
| 上り (ルーター=送信側) | 50ms | 500M → 497 (0.07%) | — | 88-95 |

- RTT≈0 なら 1.5 Gbps でもサーバー CPU ~55-65%。
- RTT 50ms では送信側の単スレッドが ~500-780 Mbps で 100% に達する。
- 下り speedtest ではサーバーが送信側 → 実環境の観測と一致。
- 素通し (トンネルなし) は 22.5 Gbps。環境の限界ではない。

### ホットスポット (perf, 下り, 50ms, 800M 要求時)

| Overhead (self) | 関数 |
|---|---|
| **62.0%** | `xqc_conn_reinject_unack_packets` |
| 18.7% | `xqc_deadline_reinj_can_reinject` |

- reinjection=deadline は unacked パケット (在庫量 ∝ RTT × レート) を毎 tick 走査する。
  これが RTT 依存コストの主成分 (暗号化・コピーは上位に来ない)。

### その他の計測済みチューニング (50ms, 上り 500M, 送信側=ルーター)

| 設定 | 送信側 CPU | 備考 |
|---|---|---|
| wlb + bbr (現行) | 88-95 | 基準 |
| scheduler=minrtt + bbr | 79-82 | CPU -15% (帯域同等) |
| wlb + cc=cubic | 84-86 | CPU -10% |

### reinjection=off の場合 (参考: ロス回復の利点を失う)

| 要求 | 受信 | サーバー CPU |
|---|---|---|
| 800M | 737-763 (5-8%) | ~40-51% |
| 2500M (ピーク付近) | ~1.6-2.0 Gbps (22-37%) | 67-86% (**ルーター側が 86-117% で飽和**) |

- 送信側の reinjection 支配が消えると上限は ~2 Gbps まで開くが、次の壁は
  クライアント側 (受信側) の単スレッドになる。

## 推論

1. 600 Mbps の壁の正体は **reinjection=deadline の unacked 走査コスト**。
   RTT が大きい環境 (実回線 10-100ms) ほど在庫が増えて単スレッドを消費する。
2. 実運用の対処候補 (効果の検証順):
   - 送信側の reinjection コスト削減 (xquic 側の改善 / パッチ)。
   - server 2 インスタンス化 (2 vCPU 活用, 別ポート/別サブネット, 下流を分割)。
   - scheduler=minrtt / cc=cubic で CPU 余裕を確保。
   - reinjection=off (ロス回復とのトレードオフ要確認)。
3. reinjection=off でも ~2 Gbps でクライアント側が壁になるため、帯域がさらに
   必要な場合は両端の処理削減かインスタンス分割が必要。

## 残課題

- 不均質 (RTT 15-75ms 混在) + ロス 0.2-1% でトンネルがほぼ停止する条件の詳細化。
- idle/dgram モードの CPU 特性。
- 上り方向 (ルーター=送信側) の reinjection=off・パッチ効果。