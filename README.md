# OpenMQVPNRouter

MQVPN クライアント (マルチWAN対応 ルーター)

# How to Build & Run

## ISOイメージのビルド

`nix build path:.#nixosConfigurations.iso.config.system.build.isoImage`

## USBメモリへの書き込み

`sudo dd if=result/iso/mqvpn-router.iso of=/dev/<デバイス名> bs=4M status=progress conv=fdatasync`

## インストール

1. ISOを起動

```sh
sudo ./install-router.sh <インストール先のディスクのパス>
```

# Configuration

## mqvpn.conf

`mqvpn.conf` は Nix ビルド時に自動生成される。認証情報 (`server_addr`, `auth_key`) は `mqvpn-auth.json`（gitignore）に分離しており、それ以外の項目は `configuration.nix` 内の Nix 式で管理される。

`mqvpn-auth.json.example` をコピーして `mqvpn-auth.json` を作成し、`server_addr` と `auth_key` を実際の値に書き換える。

```sh
cp mqvpn-auth.json.example mqvpn-auth.json
# 中身を編集
```

`mqvpn-auth.json` が存在しない場合、`builtins.readFile` により Nix ビルド時にエラーとなる。認証情報のみを切り離しているので、NIC 構成などを変更しても再度認証情報を設定する必要はない。

### 構成要素

| 要素 | 管理方法 |
|------|----------|
| `server_addr`, `auth_key` | `mqvpn-auth.json`（gitignore, 手動管理） |
| 全キー（上記含む）のデフォルト値 | `configuration.nix` の `mqvpnConfig` let 内 |
| `paths` (NIC 一覧) | `services.mqvpn.interfaces` オプション |


# Lab (3VM: mogami-vm + mogami-server + mogami-client)

ルーター VM (mogami-vm) + サーバー VM (mogami-server) + クライアント VM (mogami-client) の 3VM ラボ環境。
MQVPN は 5 本の tap WAN NIC 経由でサーバー VM にマルチパス接続し、そのトンネルをクライアントが利用する。

## 構成

```
host
  ├── bridge mqvpn-br0
  │     ├── tr-mq  ────── mogami-vm (eth1 = LAN)
  │     └── tc-mq  ────── mogami-client (eth0 = LAN)
  │
  ├── bridge mqvpn-srv-br0
  │     ├── trw0-4 ────── mogami-vm (eth2/4-7 = WAN)
  │     └── ts-mq  ────── mogami-server (eth1 = LAN)
  │
  ├── SSH :2222 ──── mogami-client (eth1 = SSH管理)
  ├── SSH :2223 ──── mogami-vm (eth3 = SSH管理)
  ├── SSH :2224 ──── mogami-server (eth0 = SSH管理)
  └── HTTP :8080 ──── mogami-vm (eth3, glances ダッシュボード)

  WAN: 5× tap (eth2/4-7) → mqvpn-srv-br0 → mogami-server (10.200.0.1:443)
```

### IP range 一覧

| セグメント | Range | 構成 |
|-----------|-------|------|
| LAN (Client↔Router) | `172.16.0.0/12` | Router `172.16.0.1`, Client `172.16.0.2` |
| WAN (Router↔Server) | `10.200.0.0/24` | Server `10.200.0.1`, Router `10.200.0.2-6` (5 WAN パス) |
| MQVPN トンネル | `192.168.0.0/24` | Server `192.168.0.1` (server mode), Router `192.168.0.x` (client) |
| 管理 (SLiRP) | `10.0.2.0/24` | 各VM独立のQEMU SLiRP (衝突しない) |

### NAT 境界 (3段)

Client がインターネットに出るまで 3 段の NAT が直列に入る:

```
Client (172.16.0.2)
  → [NAT 1: Router] MASQUERADE on mqvpn0
    → MQVPN tunnel (192.168.0.0/24)
      → [NAT 2: Server] MASQUERADE on eth0 (QEMU user-mode)
        → QEMU user-mode (10.0.2.0/24)
          → [NAT 3: QEMU SLiRP] ホストネットワークへ
```

| # | NAT 元 → 出力先 | 実施場所 | 設定ファイル |
|---|----------------|----------|-------------|
| 1 | `172.16.0.0/12` → `mqvpn0` | Router VM | `test/mogami-vm.nix:62-68` |
| 2 | `192.168.0.0/24` → `eth0` (QEMU user-mode) | Server VM | `test/mogami-server.nix:61-66` |
| 3 | QEMU user-mode NIC (`10.0.2.x`) → ホストNW | QEMU プロセス (SLiRP) | 各 start スクリプトの `-netdev user` |

- **NAT 1**: ルーターが LAN からのトラフィックを MQVPN トンネルに通す
- **NAT 2**: サーバーがトンネル復元後のトラフィックを QEMU user-mode NIC 経由で外に出す
- **NAT 3**: QEMU が VM 内部の user-mode IP をホストのネットワークに NAT する

- **mogami-vm**: ルーター (DHCP/DNS/ファイアウォール/NAT/MQVPNクライアント)
- **mogami-server**: MQVPN サーバー (トンネル終端, NAT2: tunnel→WAN, `10.200.0.1:443` で待受)
- **mogami-client**: 下流クライアント（静的IP 172.16.0.2/12, デフォルトGW 172.16.0.1）

### mogami-vm ネットワークインターフェース

`build-vm` がデフォルトで旧 `-net` 記法の NIC（`eth0`）を生やし、`net.ifnames=0` を強制するためインターフェース名は常に `ethX` になる。

| Interface | 役割 | 方式 |
|-----------|------|------|
| `eth0` | build-vm default (unused) | IPv4LL |
| `eth1` | LAN (tap tr-mq → mqvpn-br0) | 172.16.0.1/12 固定 |
| `eth2` | WAN0 (tap trw0 → mqvpn-srv-br0) | 10.200.0.2/24 固定 |
| `eth3` | SSH管理 (hostfwd `:2223`→`:22`) | DHCP (10.0.2.0/24) |
| `eth4` | WAN1 (tap trw1 → mqvpn-srv-br0) | 10.200.0.3/24 固定 |
| `eth5` | WAN2 (tap trw2 → mqvpn-srv-br0) | 10.200.0.4/24 固定 |
| `eth6` | WAN3 (tap trw3 → mqvpn-srv-br0) | 10.200.0.5/24 固定 |
| `eth7` | WAN4 (tap trw4 → mqvpn-srv-br0) | 10.200.0.6/24 固定 |

注意点:
- VM ビルダーが `boot.kernelParams` に `net.ifnames=0` を追加するため、`usePredictableInterfaceNames` の設定は実質無効になる。
- この VM には disko/impermanence の設定は含まれていない（実機向け `mogami` 設定のみ）。
- WAN の tap NIC (`eth2`, `eth4-7`) はブリッジ `mqvpn-srv-br0` 経由でサーバー VM に接続する。

## 使い方

### 事前準備

```sh
cp mqvpn-auth.json.example mqvpn-auth.json
# 実サーバーの server_addr と auth_key を記入
```

### 一括起動（推奨）

```sh
./test/up.sh
```

内部で以下を順次実行:
1. 既存のラボを停止 (`stop-mogami-lab.sh`)
2. 3 VM すべてを Nix ビルド (`build-mogami-lab.sh`)
3. 2 つのブリッジ (`mqvpn-br0` + `mqvpn-srv-br0`) + tap インターフェースを作成
4. 3 VM をバックグラウンドで起動（ログは `/tmp/mqvpn-{router,server,client}.log`）

終了するには `./test/stop-mogami-lab.sh` を実行する。

### SSH 接続

```sh
./test/ssh-router.sh       # ルーターに接続 (password: router)
./test/ssh-server.sh       # サーバーに接続 (password: server)
./test/ssh-client.sh       # クライアントに接続 (password: test)
```

### 個別操作

| 操作 | コマンド |
|------|----------|
| ビルド + ブリッジ作成 | `./test/build-mogami-lab.sh` |
| ルーター起動（フォアグラウンド） | `./test/start-mogami-router.sh` |
| サーバー起動（フォアグラウンド） | `./test/start-mogami-server.sh` |
| クライアント起動（フォアグラウンド） | `./test/start-mogami-client.sh` |
| 終了・クリーンアップ | `./test/stop-mogami-lab.sh` |
