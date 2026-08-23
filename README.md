# OpenMQVPNRouter

MQVPN クライアント (マルチWAN対応 ルーター)

# 要するに

## 構築手順

1. Nixをインストールする(Windows非対応。WSLとか使ってください)。https://github.com/NixOS/nix-installer が良いと思います。
1. サーバを設定する(https://github.com/mp0rta/mqvpn の`README.md`などを参照)
1. ./configuration.nixのservices.mqvpn.interfacesを、WANを接続する可能性のあるNIC一覧に書き換える。
  一番安定している回線（低レイテンシ・高信頼）は、ここで一番初めに指定したNICに接続すると良い。
  初期ハンドシェイクはこの回線で行われるため、起動時の接続が最も速くなる。
1. Configuration の欄にある指示に従い、mqvpn-auth.jsonを作る
1. How to Build & Runの指示に従い、ルータPCにインストールする

## ひとことメモ

分からないことがあれば、このリポジトリのコントリビュータかLLMに聞いてください。
NICの一覧は`ip a`、ディスクの一覧は`lsblk -d`で出ます。
configuration.nixの編集については、とりあえずインストーラを起動してからインストーラ環境で`ip a`をして、
NIC一覧を見てからローカルで編集し、commitとpushをする という形で良いかもしれません。
./install-router.shは自動で`git pull`してくれます。

## ちなみに

chiken/の内容は、LLMの、LLMによる、LLMのためのメモ集です。
たぶん人は読まない方が良いです

## テスト環境

実機にある程度近い環境をVMで立てます。
詳しくは下の方にあります。

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
  │     ├── tr-mq  ────── mogami-vm (eth0 = LAN)
  │     └── tc-mq  ────── mogami-client (eth0 = LAN)
  │
  ├── bridge mqvpn-srv-br0
  │     ├── trw0-4 ────── mogami-vm (eth1/3-6 = WAN)
  │     └── ts-mq  ────── mogami-server (eth1 = LAN)
  │
  ├── bridge mq-mgmt-br0 (192.168.50.0/24, 管理専用, forwarding=0)
  │     ├── tr-mgmt ───── mogami-vm (eth2 = 管理, 192.168.50.1)
  │     ├── ts-mgmt ───── mogami-server (eth0 = 管理, 192.168.50.2)
  │     └── tc-mgmt ───── mogami-client (eth1 = 管理, 192.168.50.3)
  │
  ├── SSH digicre@192.168.50.1 ── mogami-vm (password: router)
  ├── SSH digicre@192.168.50.2 ── mogami-server (password: server)
  ├── SSH testuser@192.168.50.3 ── mogami-client (password: test)
  └── HTTP http://192.168.50.1/ ── mogami-vm (eth2, glances ダッシュボード)

  WAN: 5× tap (eth1/3-6) → mqvpn-srv-br0 → mogami-server (10.200.0.1:443)
```

### IP range 一覧

| セグメント | Range | 構成 |
|-----------|-------|------|
| LAN (Client↔Router) | `172.16.0.0/12` | Router `172.16.0.1`, Client `172.16.0.2` |
| WAN (Router↔Server) | `10.200.0.0/24` | Server `10.200.0.1`, Router `10.200.0.2-6` (5 WAN パス) |
| MQVPN トンネル | `192.168.0.0/24` | Server `192.168.0.1` (server mode), Router `192.168.0.x` (client) |
| 管理 | `192.168.50.0/24` | 専用 tap ブリッジ `mq-mgmt-br0` (Router .1 / Server .2 / Client .3、VM 内にデフォルトルート無し) |

### NAT 境界 (1段 + 出口なし)

クライアントがトンネルに入るまでに NAT が 1 段入る。トンネル復元後のトラフィックはサーバーに NAT/フォワーディングが無いため、サーバー内でドロップされる (純ラボ島):

```
Client (172.16.0.2)
  → [NAT 1: Router] MASQUERADE on mqvpn0 (mark ベース)
    → MQVPN tunnel (192.168.0.0/24)
      → サーバーは転送しない (NAT/ip_forward 無し → ドロップ)
```

| # | NAT 元 → 出力先 | 実施場所 | 設定ファイル |
|---|----------------|----------|-------------|
| 1 | `172.16.0.0/12` → `mqvpn0/1` (mark ベース MASQUERADE) | Router VM | `test/mogami-vm.nix:81`, `configuration.nix:204` |

- **NAT 1**: ルーターが LAN からのトラフィックを MQVPN トンネルに通す
- トンネル復元後のトラフィックはサーバーが転送せずにドロップ (インターネット egress は無い)

- **mogami-vm**: ルーター (DHCP/DNS/ファイアウォール/NAT/MQVPNクライアント)
- **mogami-server**: MQVPN サーバー (トンネル終端, 出口なし, `10.200.0.1:443` で待受)
- **mogami-client**: 下流クライアント（静的IP 172.16.0.2/12, デフォルトGW 172.16.0.1）

### mogami-vm ネットワークインターフェース

`build-vm` がデフォルトで旧 `-net` 記法の NIC（`eth0`）を生やし、`net.ifnames=0` を強制するためインターフェース名は常に `ethX` になる。

| Interface | 役割 | 方式 |
|-----------|------|------|
| `eth0` | LAN (tap tr-mq → mqvpn-br0) | 172.16.0.1/12 固定 |
| `eth1` | WAN0 (tap trw0 → mqvpn-srv-br0) | 10.200.0.2/24 固定 |
| `eth2` | 管理 (tap tr-mgmt → mq-mgmt-br0) | 192.168.50.1/24 固定 (ルート無し) |
| `eth3` | WAN1 (tap trw1 → mqvpn-srv-br0) | 10.200.0.3/24 固定 |
| `eth4` | WAN2 (tap trw2 → mqvpn-srv-br0) | 10.200.0.4/24 固定 |
| `eth5` | WAN3 (tap trw3 → mqvpn-srv-br0) | 10.200.0.5/24 固定 |
| `eth6` | WAN4 (tap trw4 → mqvpn-srv-br0) | 10.200.0.6/24 固定 |

注意点:
- VM ビルダーが `boot.kernelParams` に `net.ifnames=0` を追加するため、`usePredictableInterfaceNames` の設定は実質無効になる。
- この VM には disko/impermanence の設定は含まれていない（実機向け `mogami` 設定のみ）。
- WAN の tap NIC (`eth1`, `eth3-6`) はブリッジ `mqvpn-srv-br0` 経由でサーバー VM に接続する。
- 管理はブリッジ `mq-mgmt-br0` (192.168.50.0/24) 経由。VM 内に mgmt のデフォルトルートは置かない (テスト経路の外への経路を構造的に持たない)。

## 使い方

### 一括起動（推奨）

```sh
./test/up.sh
```

内部で以下を順次実行:
1. 既存のラボを停止 (`stop-mogami-lab.sh`)
2. 3 VM すべてをビルド (`build-mogami-lab.sh`)
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
