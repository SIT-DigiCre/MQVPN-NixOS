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

`mqvpn-auth.json` が存在しない場合は `server_addr` と `auth_key` は空になり、MQVPN は接続できない。認証情報のみを切り離しているので、NIC 構成などを変更しても再度認証情報を設定する必要はない。

### 構成要素

| 要素 | 管理方法 |
|------|----------|
| `server_addr`, `auth_key` | `mqvpn-auth.json`（gitignore, 手動管理） |
| 全キー（上記含む）のデフォルト値 | `configuration.nix` の `mqvpnConfig` let 内 |
| `paths` (NIC 一覧) | `services.mqvpn.interfaces` オプション |


# Test (mogami-vm)

`test/mogami-vm.nix` により、`configuration.nix` をベースに QEMU/KVM 仮想環境向けに調整したテスト用 VM をビルドできる。

## ビルド

```sh
nix build path:.#nixosConfigurations.mogami-vm.config.system.build.vm
```

## ネットワーク構成（mogami-vm）

`build-vm` がデフォルトで旧 `-net` 記法の NIC（`eth0`）を生やす。VM ビルダーが `net.ifnames=0` を強制するためインターフェース名は常に `ethX` になる。

| Interface | 役割 | 方式 |
|-----------|------|------|
| `eth0` | build-vm default (unused) | IPv4LL |
| `eth1` | LAN (tap tr-mq → mqvpn-br0) | 172.16.0.1/12 固定 |
| `eth2` | WAN0 (tap trw0 → mqvpn-srv-br0) | 10.200.0.2/24 固定 |
| `eth3` | SSH管理 (hostfwd `:2223`→`:22`) | 10.0.3.15/24 固定 |
| `eth4` | WAN1 (tap trw1 → mqvpn-srv-br0) | 10.200.0.3/24 固定 |
| `eth5` | WAN2 (tap trw2 → mqvpn-srv-br0) | 10.200.0.4/24 固定 |
| `eth6` | WAN3 (tap trw3 → mqvpn-srv-br0) | 10.200.0.5/24 固定 |
| `eth7` | WAN4 (tap trw4 → mqvpn-srv-br0) | 10.200.0.6/24 固定 |

WAN は 5 本の tap NIC 経由でサーバー VM（`mogami-server` / 10.200.0.1）にマルチパス接続する。
SSH 管理用 NIC (`eth3`) のみ `hostfwd` を用いる。

### 注意点

- VM ビルダーが `boot.kernelParams` に `net.ifnames=0` を追加するため、`usePredictableInterfaceNames` の設定は実質無効になる。インターフェース名は常に `ethX`。
- disko/impermanence は実環境と同じく有効。VM 内のディスクイメージ上で Btrfs サブボリュームのロールバックや /persist への保存をテストできる。
- WAN の tap NIC (`eth2`, `eth4-7`) はブリッジ `mqvpn-srv-br0` 経由でサーバー VM に接続する。

# Lab (mogami-vm + mogami-client)

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

- **mogami-vm**: ルーター (DHCP/DNS/ファイアウォール/NAT/MQVPNクライアント)
- **mogami-client**: 下流クライアント（静的IP 172.16.0.2/12, デフォルトGW 172.16.0.1）

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
1. 既存のラボを停止
2. mogami-vm + mogami-client を Nix ビルド
3. クライアント用ブリッジ `mqvpn-br0` + tap インターフェースを作成
4. 2 VM をバックグラウンドで起動（ログは `/tmp/mqvpn-{router,client}.log`）

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
