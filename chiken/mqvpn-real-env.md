# 実環境 (プロダクション) 調査レポート — 回線特性・フロー分散・環境状態

> 2026-08-27 夜 調査時点。接続情報・構成・計測値・残したツール・引き継ぎを 1 本にまとめたもの。
> 能動試験は終盤のみ実施 (ユーザが回線を 1 本切断した時点で中断)。

## 1. アクセス経路

| ノード | 到達方法 | 備考 |
|---|---|---|
| サーバ | `ssh digicre@サーバIP (mqvpn-auth.json の server_addr)` (:22) | hostname `dc-gasyuku-mqvpn-rt-test`。sudo 不可、docker は sudo 不要で使える |
| 実ルータ | `ssh digicre@172.16.0.1` | hostname `mogami`。手元マシンの enp130s0 (172.16.0.54/12) がルータ LAN に直結 |
| ルータ WAN (外から) | endpoint ルータの NAT エンドポイント (非公開) | 外部 SSH は遮断 (到達不可) |

- ルータのトンネル IP: mqvpn0=192.168.0.2 / mqvpn1=192.168.1.2 (サーバ側は 192.168.0.1 / 192.168.1.1)。
- サーバの FW は外部に **22 のみ**解放 (5201/5202 は当初遮断 → 調査中にユーザが 5202 を解放)。
- 手元の `~/.ssh/known_hosts` が cross-device symlink で更新不能 (既知の cosmetic エラー)。

## 2. 構成 (観測で確定した実トポロジ)

```
[実ルータ mogami @ 合宿地]
  ├─ mqvpn client ×2 (ports 443/444) — 同一の 3 物理回線を共有 (shared paths)
  │    └─ ECMP (L4 ハッシュ) でユーザフローを 2 トンネルへ ~50:50 振分
  └─ LAN 172.16.0.0/12 のユーザ群
        │ QUIC (3 paths: path_id 0/1/3)
        ▼
[サーバ] docker compose: mqvpn-server-0/1 + prometheus + grafana
```

- **デプロイ状態**: サーバの repo は commit `201efbb` = **C 版パッチ (容量ピークピン) 適用済み**の
  ツリーと同一。ルータも C 版ビルド (mqvpn store: `ahqb0m51075i...-mqvpn-0.16.1`)。コンテナは 21:05 に再デプロイ。
- ルータの WAN NIC 定義は 7 本 (`enp1s0f0..f3, enp6s0, enp8s0, enp9s0`)。現在 **3 回線**が active:

| NIC | IP | GW | 備考 |
|---|---|---|---|
| enp1s0f0 | 192.168.4.204/24 | 192.168.4.1 | 独立した上流 |
| enp1s0f2 | 192.168.1.146/24 | 192.168.1.1 | ← **f3 と同一 GW/セグメント** (同一上流の 2 ケーブル?) |
| enp1s0f3 | 192.168.1.175/24 | 192.168.1.1 | 同上 |

- 25h 履歴には 5 パス時代 (path 2, 13) があり、path2 はピーク 79Mbps・cwnd 20MB の太い回線だった
  (現在は未接続/閉塞)。未接続 NIC は journal に `path4..6 closed` と出る。
- サーバ側コンテナ: `mqvpn-server-0` (443, tunnel 192.168.0.0/24), `mqvpn-server-1` (444, 192.168.1.0/24)。
- 監視: prometheus (127.0.0.1:9000) + grafana (:3000)。exporter 9091/9093 → コンテナ内 **mqvpn control API**
  (`127.0.0.1:9090`, TCP, `{"cmd":"get_status"}`) を scrape。

## 3. 物理回線の特性 (実測)

### 3.1 RTT

| NIC | avg | min | max |
|---|---|---|---|
| enp1s0f0 | 24.8ms | 19.8 | 30.7 |
| enp1s0f2 | 22.5ms | 15.9 | 31.0 |
| enp1s0f3 | 23.1ms | 16.2 | 40.9 |

(ルータ→サーバ直結 ping、各 NIC)

- **3 回線ともベース RTT 14–17ms** でほぼ同帯 — 同一拠点・同種回線 (同じ ISP 系) と推定。
  ラボの latab (10/200/50ms) や想定の「Starlink 級 40ms」よりずっと近い。
- 負荷時 srtt: 中央 27–32ms、スパイク **139–461ms** (バースト inflight による深いキュー)。
  平常時は 20–40ms で安定。

### 3.2 ロス

- パス別パケットロス (5 分間・実ユーザ負荷): path0 +2 / path1 +6 / path3 +2 — **極小**。
- データグラムロスは累計 **116k / 8.38M 送信 ≈ 1.4%** (コンテナ loss checkpoint)。
  ラボは 0% だったので、これが**実回線の現実のロス率**。`reinjection=deadline` が吸収しており、
  パス別 pkt_lost が小さいのは再注入が効いている証拠。

### 3.3 容量 (能動試験)

- **上り 48.3 Mbps** (P=20, ルータ→サーバ tunnel IP)。
- **下り 80–216 Mbps** (P=20, 実行ごとにばらつき。216M が最大観測) → 回線は下り優位の**非対称** (約 4.5:1)。
- 直結 (トンネル迂回・回線単体) の容量は FW 遮断で未完。25h のパス別送信ピーク (5 分窓) は
  path0 4.8MB/s / path1 2.9MB/s / path3 2.3MB/s (負荷ピークであり容量上限ではない)。

## 4. フロー分散 (実測)

### 4.1 実ユーザ受動観測 (5 分間, 下り ~60Mbps / 上り ~8Mbps)

| 方向 | path 0 | path 1 | path 3 |
|---|---|---|---|
| 下り (server→router) | **53%** | 34% | 13% |
| 上り (router→server) | 34% | 30% | **37%** |

- **1 パスへの崩壊なし**。ラボの「高 RTT パス飢餓」は本番では起きていない (全回線が 15ms 級で RTT 差が小さい)。
- 下りの傾斜 (53/34/13) は **C 版の設計どおり「実証済み容量ピーク比例」** と整合:
  25h の送信ピーク比 (4.8:2.9:2.3) の順と一致する。
- 上りはほぼ均等。トンネル間 ECMP は ~50:50 (セッション累計 11.76GB 対 11.76GB、差は 223B)。

### 4.2 path 別の負荷挙動 (5 分間)

| パス | srtt 中央 | srtt 最大 | cwnd 最大 | inflight 最大 | ロス |
|---|---|---|---|---|---|
| 0 | 27–28ms | 418–461ms | **43MB** | 6.3MB | +2 |
| 1 | 28ms | 139–149ms | 9MB | 1.9MB | +6 |
| 3 | 30–32ms | 188–203ms | 10MB | 2.8MB | +2 |

→ path0 が最太の回線で、バースト吸収役 (inflight が 6MB 級まで張る)。

## 5. サーバ余力

- mqvpn-server-0: CPU 0.58% / server-1: 0.00%、メモリ ~55MB/3.77GB。
- 合計 ~60Mbps×2 トンネルをほぼ無負荷で処理。**サーバは 70 人規模の数倍まで余裕**。

## 6. 所見・示唆

1. **C 版スケジューラは本番で正常動作**: 下りが容量ピーク比例で分散し、飢餓なし。
   回線の太さの差を実測から自動学習して配分している。
2. **回線は同 RTT・容量差ありの 3 本構成**。帯域不均一は path0 と他 2 本の間で存在するが、
   C 版のピーク比例が吸収している。f2/f3 が同一上流なら「実質 2 上流」であり、
   上流障害時に 2 パス同時死亡し得る点は要注意。
3. **実回線ロス 1.4%** は無視できない水準 — reinjection=deadline が効いているが、
   スパイク時の srtt 上昇 (183ms) と合わせ、負荷時の体感遅延はキューイング由来が主。
4. **path3 の下りシェア 13%** は C 版の床 (max_peak/2 → 期待 ~20%) をやや下回る。
   原因候補: (a) path3 の下り容量が実際に小さい、(b) srtt が高め (97ms) で配信ピークが育ちにくい。
5. **ルータ側の上りピン分布は journal STATUS で観測可** (`journalctl -u mqvpn-0`)。
   相対時刻 `--since "-2s"` は効かない → **`--since "1 minute ago"` を使う**。

## 7. 残したツール・引き継ぎ

- サーバ: docker iperf3 (host network) を **192.168.0.1:5202 (iperfA) と 192.168.1.1:5203 (iperfB)** で
  起動済み (image `networkstatic/iperf3` pull 済み)。旧 iperf3 デーモン (5201–5204) は kill 済み。
  FW は 5202 が解放された状態。
- ルータ: `/tmp/tunnel-test.sh` (iperf3 + STATUS サンプラ)。ネイティブ iperf3 あり。
- control API の叩き方:
  `docker exec mqvpn-server-0 sh -c 'exec 3<>/dev/tcp/127.0.0.1/9090 && printf "{\"cmd\":\"get_status\"}" >&3 && cat <&3'`
- Prometheus の主要メトリクス: `mqvpn_path_srtt_seconds`, `mqvpn_path_bytes_tx_total`,
  `mqvpn_path_cwnd_bytes`, `mqvpn_path_in_flight_bytes`, `mqvpn_path_pkt_lost_total`,
  `mqvpn_client_app_bytes_total` (label: path_id)。
- **未解決**: 調査終盤にユーザが 1 パスを切断した状態で中断 (failover 挙動は未観測)。
  再接続時は `get_status` の n_paths で現行パス数を確認すること。
- 残テスト: P=1 単フロー上限 / P=60 / 40s 長回し / 2 パス時 (failover 後) の再配分 / f2・f3 が
  同一上流かの切り分け (片方のケーブルを抜く)。
