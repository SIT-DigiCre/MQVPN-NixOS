# MQVPN テスト環境 (Lab / 4VM)

実機に近い環境を VM で立てる。

構成: **ルーター VM (mogami-vm) + サーバー VM (mogami-server) + クライアント VM (mogami-client)
+ mnet VM (mogami-mnet)** の 4VM。

## 構成

```
host
  ├── bridge mqvpn-br0
  │     ├── tr-mq  ────── mogami-vm (eth0 = LAN)
  │     └── tc-mq  ────── mogami-client (eth0 = LAN)
  │
  ├── bridge mqvpn-srv-br0
  │     ├── trw0-11 ───── mogami-vm (eth1/3-13 = WAN)
  │     └── ts-mq  ────── mogami-server (eth1 = LAN)
  │
  ├── bridge mq-ext-br0 (192.168.100.0/24, mnet 専用)
  │     ├── ts-ext ────── mogami-server (eth2 = mnet 側出口)
  │     └── tm-ext ────── mogami-mnet (eth0 = 192.168.100.1)
  │
  ├── bridge mq-mgmt-br0 (192.168.50.0/24, 管理専用, forwarding=0)
  │     ├── tr-mgmt ───── mogami-vm (eth2 = 管理, 192.168.50.1)
  │     ├── ts-mgmt ───── mogami-server (eth0 = 管理, 192.168.50.2)
  │     ├── tc-mgmt ───── mogami-client (eth1 = 管理, 192.168.50.3)
  │     └── tm-mgmt ───── mogami-mnet (eth1 = 管理, 192.168.50.4)
  │
  ├── SSH digicre@192.168.50.1 ── mogami-vm (password: router)
  ├── SSH digicre@192.168.50.2 ── mogami-server (password: server)
  ├── SSH testuser@192.168.50.3 ── mogami-client (password: test)
  ├── SSH digicre@192.168.50.4 ── mogami-mnet (password: mnet)
  └── HTTP http://192.168.50.1/ ── mogami-vm (eth2, glances ダッシュボード)

  WAN: 12× tap (eth1/3-13) → mqvpn-srv-br0 → mogami-server (10.200.0.1:443)
```

## IP range 一覧

| セグメント | Range | 構成 |
|-----------|-------|------|
| LAN (Client↔Router) | `172.16.0.0/12` | Router `172.16.0.1`, Client `172.16.0.2` (DHCP) |
| WAN (Router↔Server) | `10.200.0.0/24` | Server `10.200.0.1`, Router `10.200.0.2-13` (12 WAN パス) |
| MQVPN トンネル (ECMP) | `192.168.0.0/24` / `192.168.1.0/24` | Server `192.168.0.1` / `192.168.1.1` (server mode)、Router `192.168.0.x` / `192.168.1.x` (client)。server-0/1 で別 subnet |
| mnet (ベンチターゲット) | `192.168.100.0/24` | mnet `192.168.100.1`、Server eth2 `192.168.100.2` |
| 管理 | `192.168.50.0/24` | 専用 tap ブリッジ `mq-mgmt-br0` (Router .1 / Server .2 / Client .3 / mnet .4、VM 内にデフォルトルート無し) |

## NAT 境界 (2段)

クライアント→トンネル間に NAT が 1 段、トンネル復元後はサーバー OCI コンテナが NAT して
mnet / 上流へ出す。mnet 宛は NAT2 後に server VM の eth2 (mq-ext-br0) 経由で `192.168.100.0/24` へ。

| # | NAT 元 → 出力先 | 実施場所 |
|---|----------------|----------|
| 1 | `172.16.0.0/12` → `mqvpn0/1` (mark ベース MASQUERADE) | Router VM (`configuration.nix` の mqvpn モジュール。iptables 行は `configuration.nix:214`) |
| 2 | `192.168.0.0/24`、`192.168.1.0/24` → `eth0` (本家スクリプト) | Server VM OCI コンテナ (`container/mqvpn-server-image.nix`) |

- **NAT 1**: ルーターが LAN トラフィックを MQVPN トンネルへ通す。
- **NAT 2**: サーバーコンテナのエントリポイントが `/etc/mqvpn/server*.conf` ごとに
  本家 `mqvpn-server-nat.sh setup` を実行。`ip_forward` は VM 側で宣言的に有効化
  (コンテナは分離 netns のため net.* sysctl を書けず、VM 側で有効化)。

## 各 VM の役割

- **mogami-vm**: ルーター (DHCP/DNS/ファイアウォール/NAT/MQVPNクライアント)
- **mogami-server**: MQVPN サーバー。**OCI イメージ (container/) を VM 内 docker で実行**
  (トンネル終端 + NAT 2, `10.200.0.1:443` で待受)。ECMP で `mqvpn-server-0`/`mqvpn-server-1`
  の 2 コンテナが独立 netns で動作。
- **mogami-client**: 下流クライアント（DHCP で 172.16.0.x/12 を取得, GW/DNS 172.16.0.1）
- **mogami-mnet**: 「実ネットワーク側」のベンチターゲット (192.168.100.1)。トンネル出口先。

## mogami-vm ネットワークインターフェース

VM ビルダーが `net.ifnames=0` を強制するためインターフェース名は常に `ethX` になる。

| Interface | 役割 | 方式 |
|-----------|------|------|
| `eth0` | LAN (tap tr-mq → mqvpn-br0) | 172.16.0.1/12 固定 |
| `eth1` | WAN0 (tap trw0 → mqvpn-srv-br0) | 10.200.0.2/24 固定 |
| `eth2` | 管理 (tap tr-mgmt → mq-mgmt-br0) | 192.168.50.1/24 固定 (ルート無し) |
| `eth3-13` | WAN1-11 (tap trw1-11 → mqvpn-srv-br0) | 10.200.0.3-13/24 固定 |

注意点:
- 管理はブリッジ `mq-mgmt-br0` (192.168.50.0/24) 経由。VM 内に mgmt のデフォルトルートは置かない
  (テスト経路の外への経路を構造的に持たない)。
- WAN の tap NIC (`eth1`, `eth3-13`) はブリッジ `mqvpn-srv-br0` 経由でサーバー VM に接続する。

## 使い方

### 一括起動（推奨）

```sh
./test/up.sh
```

内部で以下を順次実行:
1. 既存のラボを停止 (`stop-mogami-lab.sh`)
2. 4 VM すべてをビルド (`build-mogami-lab.sh`)
3. 3 ブリッジ (`mqvpn-br0` + `mqvpn-srv-br0` + `mq-ext-br0`) + tap インターフェースを作成
4. 4 VM をバックグラウンドで起動（ログは `/tmp/mqvpn-{router,server,client,mnet}.log`）

終了するには `./test/stop-mogami-lab.sh` を実行する。

### SSH 接続

```sh
./test/ssh-router.sh   # ルーターに接続 (password: router)
./test/ssh-server.sh   # サーバーに接続 (password: server)
./test/ssh-client.sh   # クライアントに接続 (password: test)
./test/ssh-mnet.sh     # mnet に接続 (password: mnet)
```

### 個別操作

| 操作 | コマンド |
|------|----------|
| ビルド + ブリッジ作成 | `./test/build-mogami-lab.sh` |
| ルーター起動（フォアグラウンド） | `./test/start-mogami-router.sh` |
| サーバー起動（フォアグラウンド） | `./test/start-mogami-server.sh` |
| クライアント起動（フォアグラウンド） | `./test/start-mogami-client.sh` |
| mnet 起動（フォアグラウンド） | `./test/start-mogami-mnet.sh` |
| 終了・クリーンアップ | `./test/stop-mogami-lab.sh` |
