# MQVPN ルーター構築 HOWTO (NixOS ルーター向け)

ルーター PC に NixOS を導入し、MQVPN クライアントとして動かす手順。
ISO のビルドは別マシン（Nix 入り）で行い、USB メモリ経由でルーター PC に書き込む。

## 1. 必要なもの

- x86_64 マシン（ISO ビルド用。WSL 等でも可、Windows 非対応）
- ルーター PC に書き込む USB メモリ

## 2. Nix の導入（ビルドマシン）

イメージのビルドに使う。

推奨 (flake が既定で有効):

```sh
curl -sSfL https://artifacts.nixos.org/nix-installer | sudo sh -s -- install --enable-flakes --no-confirm
```

シェルを開き直す

確認:

```sh
nix --version
nix flake --help >/dev/null && echo "flake OK"
```

## 3. ISO イメージのビルド

```sh
nix build path:.#nixosConfigurations.iso.config.system.build.isoImage
```

## 4. USB メモリへの書き込み

```sh
sudo dd if=result/iso/mqvpn-router.iso of=/dev/<デバイス名> bs=4M status=progress conv=fdatasync
```

## 5. インストール

ISO を起動し、以下を実行:

```sh
sudo ./install-router.sh <インストール先のディスクのパス>
```

`./install-router.sh` は自動で `git pull` する。

## 6. Configuration

`configuration.nix` の `services.mqvpn` モジュールで設定する。

- `services.mqvpn.interfaces`: WAN を接続する可能性のある NIC 一覧。
- `mqvpn-auth.json`（gitignore）: `server_addr` / `auth_key` を指定。
  存在しない場合ビルド時にエラー。作成は `mqvpn-auth.json.example` をコピー:

  ```sh
  cp mqvpn-auth.json.example mqvpn-auth.json
  # server_addr と auth_key を編集
  ```

- `mqvpn.conf` はビルド時に自動生成される（NIC 構成などを変更しても認証情報を
  再設定する必要はない）。

一番安定している回線（低レイテンシ・高信頼）は interfaces の**最初**に指定すると、
初期ハンドシェイクがその回線で行われ、起動時の接続が最も速くなる。

## おまけ

NICの一覧は`ip a`、ディスクの一覧は`lsblk -d`で出ます。
configuration.nixの編集については、とりあえずインストーラを起動してからインストーラ環境で`ip a`をして、
NIC一覧を見てから手元で編集し、commitとpushをする という形で良いかもしれません。

