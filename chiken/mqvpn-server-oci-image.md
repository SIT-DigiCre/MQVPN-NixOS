# MQVPN サーバー OCI イメージ化とテスト環境の docker 化

## 本家 (mp0rta/mqvpn) のサーバー定義の調査結果 (systemd/ ディレクトリ)

- **サーバーユニット**: `ExecStartPre` で `mqvpn-server-nat.sh setup /etc/mqvpn/server.conf`、
  `ExecStart` で daemon、`ExecStopPost` で teardown。`Restart=on-failure` / 5s。
  ハードニング: ProtectHome / ProtectSystem=strict / ReadOnlyPaths=/etc/mqvpn /
  ReadWritePaths=/dev/net/tun / NoNewPrivileges など。
- **mqvpn-server-nat.sh** が NAT の実体: 設定から subnet/subnet6/tun_name を読んで
  - ip_forward 有効化 (orig を /run/mqvpn に保存)
  - `MASQUERADE -s $SUBNET -o $(detect_iface)` (detect = `ip route get 8.8.8.8`)
  - FORWARD: `-i $TUN -s $SUBNET` / `-o $TUN -d $SUBNET`
  - 全て `--comment mqvpn-server-nat` を付けて、teardown はコメント一致行を
    line-number で全削除 + ip_forward 復元
  - IPv6 (subnet6) は NAT66 も同構造
- 他: `users` キー (ユーザー毎 PSK)、`max_clients`、`scheduler=wlb|minrtt`、
  `control_listen` (127.0.0.1 専用の Control API)、`mqvpn --genkey` で鍵生成。
  → **自前 NAT ロジックを書く代わりに本家スクリプトをそのまま同梱する設計を採用**
  (設定ファイルを引数に取るので server*.json ごとに呼ぶだけでマルチ daemon 対応)。

## OCI イメージの設計 (container/mqvpn-server-image.nix)

- `dockerTools.buildLayeredImage` の最小コンテナ: mqvpn バイナリ + 本家 nat スクリプト
  (ビルドと同じ fetchFromGitHub src からコピー) + entrypoint + 実行ツール群。
- entrypoint: `/etc/mqvpn/server.conf` (or MQVPN_CONF) の**単一設定のみ**扱う
  (形式は自動判定: 先頭 `{` なら JSON、それ以外は INI。名前は任意。
  **ただし MQVPN_SUBNET / MQVPN_TUN_NAME での差別化は JSON config 専用** —
  INI と組み合わせると明示エラーで即停止する)
  (**1 サーバ = 1 コンテナ**。サーバー数の埋め込みはせず、増設は運用側で
  unit/compose を並べる)。nat setup → daemon 起動 → 死んだら 5 秒で再起動
  (連続 10 回失敗で全体終了) → 終了時 teardown。
- **ネットワークモデル: bridge + ポートフォワード** (コンテナごとに独立 netns)。
  - tun / iptables / sysctl が全てコンテナ netns 内で完結 → インスタンス間干渉なし、
    **config を全インスタンス同一にできる** (listen 443 / subnet / tun_name 同一で可)
  - EPERM 問題は host-net 固有だった: bridge ではコンテナ内 ip_forward が
    実書き込みで成功する (sysctl ラッパは「実書き込み失敗時のみ握りつぶし」)
  - 例外: **同一クライアントが複数サーバーに同時接続 (ECMP) する場合のみ、
    クライアント側 netns で仮想サブネットが衝突** → subnet/tun_name を分けた
    config が必要。ラボの 2 台構成はこれに該当 (192.168.0.0/24 vs 192.168.1.0/24)
  - --network host でも動く (ホスト側で ip_forward 有効化 + netns 共有の前提)。
    ただし teardown は**単一コメント `mqvpn-server-nat` の一致行を全削除**するため、
    host netns では 1 インスタンスの再起動が他インスタンスの NAT/FORWARD ルールも
    巻き込む (再追加されるまで通信途絶)。netns 非共有の bridge (既定) のみ無害
- **ラボのベンチはコンテナ netns 内で行う**: tun が VM netns に無いため、
  iperfd (iperf3 をイメージに同梱) は docker exec でコンテナ内に設定する。
  （戻りルートは不要 — ルーター NAPT のため復路はトンネル端点宛で足りる）
- シークレット (auth_key / 証明書) はイメージ外。`-v /etc/mqvpn:/etc/mqvpn:ro`。
- daemon は `--cap-drop ALL --cap-add NET_ADMIN,NET_BIND_SERVICE` + tun デバイス渡し。

## dockerTools で踏んだ罠 (実機検証済み)

1. **dockerTools は /usr/bin/env を持たない**: エントリポイントの shebang を
   `#!/usr/bin/env bash` にすると `exec ...: no such file or directory` で起動失敗。
   → shebang は store 上の `#!${pkgs.bash}/bin/bash` を直接指す。
2. **`/bin` は contents の bin がマージされる** (iptables の xtables-* や coreutils の
   wc 等が見える): `/bin/sh` は動く。store パス以外を Cmd にする場合は
   自前の binLinks 層で symlink を生やす。
3. **コンテナから net.* sysctl 書き込みは常に EPERM** (bridge / host とも。
   docker の /proc/sys 制約。値は **netns 作成時にホスト init netns から継承される**
   ため、コンテナ netns の ip_forward はホスト側の設定だけで決まる)。
   → sysctl を「-w は成功に化ける」ラッパに差し替え、ip_forward はホスト側で
   有効化しておく (docker デーモン自体も要求する値)。
   (途中「bridge なら書けるのでは」と試したが、ip_forward:1 が観測できたのは
   継承値の見かけ — 実書き込みは bridge でも EPERM だった)
4. **Healthcheck の時間はナノ秒で書く**: `Interval = 30` (秒) は docker が
   time.Duration として 30ns と解釈し常に unhealthy。30000000000 等と書く。
5. environment.etc の symlink ファイルはコンテナから dangling (VM の /nix/store が
   見えない)。tmpfiles C! は「既存ならスキップ」の copy-once なので stale 化する
   (**! は上書きフラグではなく「boot 時のみ実行」modifier。上書きする
   modifier は存在しない**)。→ docker run の `-v <store ファイル>:<コンテナ内>:ro`
   で**ファイルバインド**する (store パス参照なので再ビルドごとに常に最新)。
6. **teardown が awk に依存 (本家 nat スクリプトの delete_by_comment:
   iptables -L ... | grep | head | awk)。イメージに awk を同梱しないと
   teardown が set -e で即中断され、--network host のホスト netns に
   NAT/MASQUERADE/FORWARD ルールが再起動のたび蓄積する**。
   (実測: 再起動 1 回で nat 2→4 / fwd 4→8 に増殖)
   対策は 2 段: ①`pkgs.gawk` を contents + PATH に同梱、②entrypoint が
   **起動時にも teardown を先行実行** (SIGKILL 等で掃除されなかった残留も自己修復)。
   検証: 同一 VM で連続 2 回再起動しても nat:2/fwd:4 で不変。
7. **docker (runc) はスクリプトの shebang 直 exec を ENOEXEC にする場合がある**
   (シェル経由や bash 引数実行では正常。ファイル内容・権限・改行は正常)。
   → Cmd は `[ "/bin/bash" "/bin/mqvpn-entrypoint" ]` とインタプリタを明示する。
8. **dockerTools 製イメージには /tmp が無い** (root は bin/dev/etc/... のみ)。
   + iperf3 サーバーは `>/dev/null` リダイレクトや --logfile 付きのバックグラウンド
   起動で「unable to create a new stream: ENOENT」で壊れる (foreground/プレーン &
   は正常)。→ iperfd 起動は `iperf3 -s -p N &` (リダイレクト無し)、必要なら
   mkdir -p /tmp。(docker exec 経由の & は exec 終了で殺されるため常駐は
   エントリポイント配下で行う)

## テスト環境 (server VM) の docker 化

- `test/mogami-server.nix` は server を VM 内 systemd service でなく、
  **docker (VM 内 daemon) で OCI イメージを実行**する構成に変更。
  本番 (自宅 Linux) と同じ作り (docker + 本家 nat スクリプト) をラボで再現。
- VM 内 docker: compose (`container/docker-compose.yml`) を systemd unit
  `mqvpn-compose` で実行。ネットワークは**bridge + ポートフォワード**
  (旧 `--network host` から変更。コンテナごとに独立 netns のため
  teardown のルール巻き込み問題が無い)。`-v /etc/mqvpn`、`--device /dev/net/tun`、
  `--cap-drop ALL --cap-add NET_ADMIN,NET_BIND_SERVICE` は compose 側で表現。
- NAT は networking.nat からコンテナ側へ移管 (VM 側は ip_forward と
  defaultGateway のみ。**defaultGateway を落とすと detect_iface が失敗し
  NAT ルールが組まれない** — 注意)。
- 検証: トンネル 2 本 UP、NAT/FORWARD 6 本、client → 実ネット curl 204、
  iperf DOWN 400M/0.001% ロス、healthcheck healthy を確認。
- 注意: VM 再起動時、systemd の ExecStartPre が旧 store path の tar を
  load するため、healthcheck 修正後のタグ反映には up.sh での再構築が必要。
- unit は `Restart = "always"` (daemon が exit 0 で死んでも再起動するよう
  on-failure ではなく always にしている)。compose には cap_drop: ALL。
  VM 側 docker は autoPrune 有効 (docker load の dangling 掃除)。

## 残課題: 上り高レートのロスばらつき (docker 起因ではない?)

- 2026-08-24 の高帯域ベンチで **UP ≥800M @50ms が 2 峰性** (792M/0.7% 〜 438M/45%、
  1000M も 955M/4.1% 〜 484M/51%)。下りは旧構成の数値を完全再現 (800M/0%、
  2500M → 2402/3.9% 一致、1500M のみ 1.4-1.6% と旧 0.4% よりやや悪い)。
- ドロップ箇所はサーバー側 `UdpRcvbufErrors` (QUIC socket 溢れ、23k パケット/12s)。
  コンテナ cgroup は無制限、daemon CPU は 55% で余裕 → docker 起因の証拠なし。
- サーバー rmem 8k→16MB/32MB に上げても解消せず。host の vCPU 奪い合いによる
  断続的な drain 遅れの可能性が高い (3 VM 同居 + ホスト共有)。
- 傾向検討 (TODO): ①旧 VM 構成との厳密 A/B (同じホストで交互数回)、②mlow:
  SO_RCVBUFFORCE / busy-poll / GRO off など受信経路の調整、③netem 送信側の
  バースト性 (pacing) の確認。

## 帯域総和の壁 (~3G、CPU 非飽和) — 2026-08-24

- multistream (UP TCP 8 フロー @0ms → mnet): 2.46-2.71G。
  DOWN 8 並列 (mnet 送信): 3.03G。単一フロー DOWN 2.3G。**総和は方向によらず
  ~2.5-3.0G で頭打ち**。
- 実行中 CPU は全 VM / 全コンテナが低負荷 (ルーター us5%+sy7%、コンテナ
  A⅛B avg 20-40%、シングル古の split 時でも 66/73%) → **サーバー (docker) でも
  ルーターでもない、ラボの NIC 層/ホスト qemu 経路の総和限界**。
- virtio-net は全て Combined: 1 (シングルキュー、VM ビルダーの素の -nic 素朴)。
  旧報告「実用上限 ~2.4-3G」と同値 = 新規劣化ではない。
- 打ち手候補: ①data NIC に virtio mq (mq=on + taps multi_queue + ethtool -L)、
  ②ホストの qemu/vhost スレッド観測でホスト律速の確定。

## 起動直後の DOWN 0/0 — 根本原因特定・修正済み (2026-08-24)

**実体**: 最初の DOWN (-R) だけ 0/0 になり、2 回目以降は必ず成功。
**根本原因 (パケットキャプチャで確定)**: mnet の iperfd が **1500-毛利ソケットで
1448 バイトのデータグラム**を送信 → 経路中のコンテナ tun (MTU 1382) が
`ICMP frag-needed (mtu 1382)` を返す → mnet の**接続型 UDP ソケットが send で
エラー化**し iperf3 の送信が即 abort → 1 秒目の 174 発で停止。その後カーネルの
PMTU 学習 (1382) により 2 回目以降は小さいフレームで成功 = 「初回だけ 0/0」。
**修正**: bench の ensure が**コンテナの tun MTU を読んで mnet の eth0 の MTU に
適用**する (PMTU 学習に依存しない)。conntrack 全 flush + 新規 iperfd の
コールド状態で 2 連続、初回 DOWN 成功 (300M/0.0035%, 400M/0.062%) を確認。
**注意**: 計測は analyse違いない = srv 側のラボ計測専用の調整 (実運用のクライアント
からの DOWN も同じ枠組みなら同一対応が必要。実物の MTU 調整は運用側)。

## 帯域総和の壁 (~3G、CPU 非飽和) — 2026-08-24
