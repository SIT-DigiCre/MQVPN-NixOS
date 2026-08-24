# MQVPN サーバー構築 HOWTO (非 NixOS / 汎用 Linux 向け)

このリポジトリの手法は「Nix で OCI イメージをビルドし、実行は素の docker compose」。
ここでは Nix の導入から、実サーバーの立て方・増設・更新までを説明する。
(NixOS 上なら Nix 導入は不要で `nix build .#mqvpn-oci` から始められる)

## 1. 必要なもの

- x86_64 Linux (Ubuntu / Debian / Fedora 等のディストロ、systemd 前提でなくても可)
- Docker (または Podman 互換の compose)
- `/dev/net/tun` (後述の手順で有効化)
- 443/tcp + 443/udp が外部から到達できること
- root で実行できる sudo 権限

## 2. Nix の導入 (flakeが必要)

イメージのビルドにのみ使う。

推奨 (flake が既定で有効):

```sh
curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install
```

確認:

```sh
nix --version
nix flake --help >/dev/null && echo "flake OK"
```

## 3. イメージのビルド

```sh
git clone <このリポジトリのURL> mqvpn-nixos
cd mqvpn-nixos
# OCIイメージのビルド
nix build .#mqvpn-oci
# docker pull
bash result/load-all.sh
```

## 4. サーバー設定 (自動生成)

証明書・認証キー・server.conf はスクリプトで一括生成する。

```sh
cd container
bash gen-mqvpn-server-config.sh            # ./mqvpn-server-conf/{server.key,server.crt,server.conf} を生成
```

- 自己署名証明書 (EC P-256) と `server.conf` (JSON) を `container/mqvpn-server-conf/` に生成する。
- `auth_key` はスクリプトが `/dev/urandom` から 32 バイトを base64 した 44 文字の文字列を自動生成
  (上流の `mqvpn --genkey` と同等)。ターミナルに表示されるので、**クライアント側
  (`mqvpn-auth.json` の `auth_key`) に同一値をコピー**すること。
- `docker-compose.yml` は `./mqvpn-server-conf` をコンテナの `/etc/mqvpn` にマウントする。

生成済みの場合はスクリプトを再実行するとエラーになる (auth_key の意図しない再発行を防ぐため)。
再生成するには `container/mqvpn-server-conf/` を削除してから実行する。

> 注意: 複数サーバー構成の差別化に使う環境変数上書き (MQVPN_SUBNET 等) は
> **JSON config 専用**。INI の server.conf と組み合わせると起動時にエラーで止まる。
>(gen-mqvpn-server-config.shによって生成されたものであれば問題ない)

## 5. ホスト（コンテナ実行環境）の準備

> 上流の `install.sh`（ネイティブ systemd 導入）なら `mqvpn-server-nat.sh setup` が
> サービス起動時に `sysctl -w net.ipv4.ip_forward=1` を一時付与（停止時に復元）し、
> 静的ファイルは不要。本リポの OCI 構成ではコンテナが書けないためホスト側で永続化する。

```sh
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-mqvpn.conf
sudo sysctl --system

# tun デバイス (ホスト側に /dev/net/tun が必要。コンテナはこれを継承)
echo 'tun' | sudo tee /etc/modules-load.d/tun.conf
sudo modprobe tun
ls -l /dev/net/tun   # 存在すれば OK

# ファイアウォール (例: ufw) — 443 を開放
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
```

## 6. compose の配置と起動

```sh
# リポジトリを clone し、その container/ 配下で compose を実行する
# (公開リポジトリは認証なしで clone 可。./mqvpn-server-conf が相対パスで解決される)
cd mqvpn-nixos/container

# 設定焼き込み済みイメージは §3 で docker load 済みであること。
# イメージのタグは mqvpn-server:latest / mqvpn-prometheus:latest /
# mqvpn-grafana:latest。手動で編集する設定は無い (scrape targets と
# ダッシュボードは nix ビルド時に compose から自動生成・焼き込み済み)

sudo docker compose up -d
sudo docker compose ps
```

mqvpn コンテナが `(healthy)` になれば起動成功。クライアント (ルーター) に
`server_addr` として本サーバーの 443 を向け、トンネルが張れることを確認する。

## 7. 監視 (Prometheus / Grafana)

compose に prometheus と grafana が含まれる。
grafanaはホストの3000番ポートで公開される。
adminの初期パスワードはadmin(変更すること。)。

```
ブラウザ: http://<サーバーIP>:3000
```

Grafana の admin パスワードは compose で平文 `admin` に設定している。
本番・共有環境では **初回ログイン時に必ず変更** すること
(admin/admin のまま放置しないよう注意)。

データの永続化: Prometheus の TSDB と Grafana の DB は **named volume**
(`prometheus-data` / `grafana-data`) に保存されるため、`--force-recreate` や
`compose down` をしても履歴・設定は消えない (nix の設定焼き込みと競合しない
書込み先だけを volume 化している)。

## 8. サーバーの増設

ECMP (同一ホスト上でクライアントインスタンスを複数立ち上げ、複数サーバーへ
同時接続) の場合 — 本ラボのルーター (`configuration.nix` の
`services.mqvpn.clientPorts`) がその構成:

1. **compose**: `mqvpn-server-2` を anchor 継承で追加 (ポートを変えるだけ —
   boilerplate は `x-mqvpn-server` 参照)
2. **prometheus イメージを再ビルド**: scrape targets はビルド時に compose から
   自動生成されるため、compose の編集以外の手編集は不要:
   ```sh
    cd mqvpn-nixos && nix build .#mqvpn-oci && bash result/load-all.sh
   cd mqvpn-nixos/container && sudo docker compose up -d --force-recreate prometheus
   ```
3. **クライアント側**: ルーターのトンネル定義に新ポート (444 等) を追加 —
   tun_name はクライアント側テンプレートが自動で一意化する

> 補足: 仮想 subnet が被っても、重複アドレスの割り当てはカーネルが許容し、
> backnet 宛トラフィックは ECMP (default ルート) でトンネル間を分割されるため
> 実用上問題ない。**必須なのは tun_name の一意化のみ** — クライアントの
> 単一 netns 内では 2 本目の tun 作成が TUNSETIFF で衝突するため。

## 9. 更新

 ```sh
  cd mqvpn-nixos
  git pull
  nix build .#mqvpn-oci
  bash result/load-all.sh
  cd mqvpn-nixos/container
  sudo docker compose up -d --force-recreate
 ```

## 10. トラブルシュート

| 事象 | 対処 |
|---|---|
| クライアントから繋がらない | `docker compose logs mqvpn-server-0`、`sudo iptables -t nat -S` で NAT ルール確認 |
| metrics が prometheus に出ない | `docker compose exec prometheus wget -qO- http://mqvpn-server-0:9091/metrics` で到達確認。exporter のエラーは `docker compose logs mqvpn-server-0 \| grep -i exporter` |
| 再起動後にトンネルが張らない | `sysctl net.ipv4.ip_forward` が 1 であること (5. の永続化) の確認|

