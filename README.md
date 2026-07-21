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
sudo ./install.sh <インストール先のディスクのパス>
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

`build-vm` がデフォルトで旧 `-net` 記法の NIC（`ens3`）を生やす。実質的な NIC は `-netdev`+`-device` で指定する。

| Interface | 役割 | 方式 |
|-----------|------|------|
| `ens3` | build-vm default (unused, DHCP off) | IPv4LL |
| `ens10` | LAN (tap tr-mq → mqvpn-br0) | 172.16.0.1/12 固定 |
| `ens11` | WAN0 (SLiRP 10.0.12.0/24) | DHCP |
| `ens12` | SSH管理 (hostfwd `:2223`→`:22`) | DHCP (デフォルトルート抑制) |
| `ens13` | WAN1 (SLiRP 10.0.4.0/24) | DHCP |
| `ens14` | WAN2 (SLiRP 10.0.6.0/24) | DHCP |
| `ens15` | WAN3 (SLiRP 10.0.8.0/24) | DHCP |
| `ens16` | WAN4 (SLiRP 10.0.10.0/24) | DHCP |

WAN は 5 本の SLiRP NIC として実サーバー（`mqvpn-auth.json` で指定）にマルチパス接続する。
SSH 管理用 NIC (ens12) のみ `hostfwd` を用いる。

### 注意点

- `build-vm` のデフォルト NIC は旧 `-net nic,netdev` 記法で作成される。`networking.usePredictableInterfaceNames = true` を設定しなければインターフェース名が `eth0` になる。
- disko/impermanence は実環境と同じく有効。VM 内のディスクイメージ上で Btrfs サブボリュームのロールバックや /persist への保存をテストできる。
- `ens3` は DHCP を完全に無効化している（未使用）。
- WAN の SLiRP NIC (`ens11`, `ens13-16`) にはデフォルトルートが生える。`ens12` のみ抑制。
- SLiRP は 1200-byte 以上の UDP 応答をゲストに転送できない場合がある（QEMU 11.0.1 の既知の制限）。tap での実ネットワーク接続に切り替えることで回避可能。

# Lab (mogami-vm + mogami-client)

ルーター VM (mogami-vm) にクライアント VM (mogami-client) を LAN 側で接続する 2VM ラボ環境。
MQVPN は 5 本の SLiRP WAN NIC 経由で実 MQVPN サーバーに接続し、そのトンネルをクライアントが利用する。

## 構成

```
host
  ├── bridge mqvpn-br0
  │     ├── tr-mq  ────── mogami-vm (ens10 = LAN)
  │     └── tc-mq  ────── mogami-client (ens3 = LAN)
  │
  ├── SSH :2222 ──── mogami-client (ens4 = SSH管理)
  ├── SSH :2223 ──── mogami-vm (ens12 = SSH管理)
  └── HTTP :8080 ──── mogami-vm (ens12, glances ダッシュボード)

  WAN: 5× SLiRP (ens11/13-16) → 実 MQVPN サーバー
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
./test/ssh-client.sh       # クライアントに接続 (password: client)
```

### 個別操作

| 操作 | コマンド |
|------|----------|
| ビルド + ブリッジ作成 | `./test/build-mogami-lab.sh` |
| ルーター起動（フォアグラウンド） | `./test/start-mogami-router.sh` |
| クライアント起動（フォアグラウンド） | `./test/start-mogami-client.sh` |
| 終了・クリーンアップ | `./test/stop-mogami-lab.sh` |
