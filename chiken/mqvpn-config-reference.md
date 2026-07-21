# MQVPN 設定項目リファレンス

バージョン: v0.13.1
ソース: config.h / config.c / mqvpn_config.c / docs.mqvpn.org

## 共通設定（クライアント・サーバー共通）

| キー | 型 | デフォルト | 意味 | 推奨 |
|------|----|-----------|------|------|
| `mode` | string | (必須) | `"client"` or `"server"` | — |
| `tun_name` | string | `"mqvpn0"` | TUN インターフェース名 | そのままでOK。複数インスタンスの場合は変更 |
| `log_level` | string | `"info"` | ログレベル: `debug`, `info`, `warn`, `error` | 運用は `info`、デバッグ時は `debug` |
| `scheduler` | string | `"wlb"` | パススケジューラ（後述） | `"wlb"` |
| `cc` | string | `"bbr2"` | 輻輳制御: `bbr2`, `bbr`, `cubic`, `none` | `"bbr2"` |
| `init_max_path_id` | u64 | `0` (= xquic default 8) | クライアントが作成可能な最大パスID。0=デフォルト(8) → 9パスまで | デフォルトのままでOK |
| `tun_mtu` | int | `0` (= 自動: クライアントはネゴシエーション, サーバーは1382) | TUN の MTU | デフォルト推奨。SLiRP環境では `1200` に下げる |
| `reorder` | object | (無効) | フロー再整列 (§16 reorder shim)。`enabled: true` で有効化 | 通常は無効でOK |
| `hybrid` | object | (無効) | Hybrid mode（後述） | 有効推奨（`enabled: true`） |

## スケジューラ一覧

| 値 | 説明 |
|----|------|
| `wlb` | 重み付きラウンドロビン。各パスのRTT/RTT変動に応じて重み付け。フロー単位でパス固定 |
| `backup_fec` | プライマリパスのみ使用。二次パスはFEC修復シンボルのみ送信 |
| `wlb_udp_pin` | WLB ベースだが、UDP フローは送信元IP:port で特定パスにピン留め |
| `minrtt` | 最小RTTのパスを常に選択。WLBより単純 |

## クライアント設定

| キー | 型 | デフォルト | 意味 | 推奨 |
|------|----|-----------|------|------|
| `server_addr` | string | (必須) | MQVPNサーバーのアドレス `"host:port"` | 実サーバーの指定 |
| `auth_key` | string | (必須) | 事前共有鍵 (PSK) | ランダム32+バイト |
| `paths` | string[] | `[]` | マルチパスに使うインターフェース名の配列。指定がなければシングルパス | マルチWANのIF一覧 |
| `dns` | string[] | `[]` | トンネル経由のDNSサーバー | お好みで (`["9.9.9.9", "1.1.1.1"]` 等) |
| `insecure` | bool | `false` | 自己署名証明書を許可（`true` でmTLS検証スキップ） | 本番は `false`（適切な証明書利用） |
| `tls_server_name` | string | — | TLS SNI。サーバー証明書の検証用 | サーバーのホスト名 |
| `reconnect` | bool | `true` | 切断時の自動再接続 | デフォルト推奨 |
| `reconnect_interval` | int | `5` | 再接続間隔（秒）。バックオフあり | デフォルトでOK |
| `kill_switch` | bool | `false` | トンネル断時に全通信を遮断（`iptables` で強制） | 必要に応じて |
| `manage_routes` | bool | `true` | ルーティング自動管理（`setup_routes()` の実行有無） | **マルチWAN時は `false`**（後述） |
| `recv_rate_limit` | u64 | `0` (無制限) | コネクション単位の受信レート制限 (bytes/sec) | 通常は無制限 |

## サーバー設定

| キー | 型 | デフォルト | 意味 | 推奨 |
|------|----|-----------|------|------|
| `listen` | string | `"0.0.0.0:443"` | サーバーのバインドアドレス `"addr:port"` | `"0.0.0.0:443"` |
| `subnet` | string | `"10.0.0.0/24"` | トンネル用IPv4サブネット（クライアントに割り当てるIP範囲） | 他と衝突しないもの |
| `subnet6` | string | — | トンネル用IPv6サブネット例: `"fd00:abcd::/112"` | 必要な場合のみ |
| `tls_cert` | string | `"server.crt"` | TLS証明書ファイルパス | 適切な証明書へのパス |
| `tls_key` | string | `"server.key"` | TLS秘密鍵ファイルパス | 適切な鍵へのパス |
| `auth_key` | string | — | サーバー側のPSK（クライアントの `auth_key` と一致） | クライアントと同じ値 |
| `users` | array | `[]` | ユーザー認証リスト（user + keyのペア） | クライアント数分 |
| `max_clients` | int | `64` | 最大同時クライアント数 | 必要に応じて |
| `control_listen` | string | (無効) | 制御APIのバインド `"addr:port"`。空文字で無効 | 管理・監視したい場合に有効化 |

## Hybrid mode 設定

```json
"hybrid": {
    "enabled": true / false (デフォルト),
    "tcp": "stream" | "raw" | "auto" (デフォルト),
    "tcp_max_flows": 256 (デフォルト),
    "tcp_idle_timeout_sec": 300 (デフォルト),
    "tcp_connect_timeout_sec": 10 (デフォルト),
    "tcp_max_global_flows": 4096 (デフォルト)
}
```

| フィールド | 値 | 意味 |
|-----------|-----|------|
| `enabled` | bool | Hybrid mode の有効/無効。デフォルト **無効** |
| `tcp` | `"stream"` | TCP レーン常時有効（≥2パス不要） |
| `tcp` | `"raw"` | TCP レーン不使用（純粋な datagram のみ） |
| `tcp` | `"auto"` | 2パス以上アクティブになった時点でTCPレーン開始 |
| `tcp_max_flows` | int | クライアントあたりの最大TCPレーン同時フロー数（デフォルト256） |
| `tcp_idle_timeout_sec` | int | TCPレーンのアイドルタイムアウト（秒） |
| `tcp_connect_timeout_sec` | int | TCPレーン接続タイムアウト（秒） |
| `tcp_max_global_flows` | int | サーバー全体の最大TCPレーン数（デフォルト4096） |

推奨: クライアント側で有効化（`enabled: true`）。`tcp: "stream"` にすると少ないパスでもTCPレーンが有効になるため、マルチパスが不完全な環境でも帯域集約の恩恵を受けやすい。

## 特別な注意が必要な設定

### `manage_routes`

`true`（デフォルト）にすると MQVPN がルーティングテーブルを書き換える:
- `ip route replace <server>/32 via <発見したGW> dev <発見したIF>` — サーバー経路を1本にピン留め
- `ip route replace 0.0.0.0/1 dev mqvpn0` — スプリットトンネル
- `ip route replace 128.0.0.0/1 dev mqvpn0` — スプリットトンネル

**マルチWAN環境では必ず `false` に設定すること。** 理由:
- サーバー経路が1つのWAN IFにピン留めされる → 他のWAN IFからのパスがFIBエントリ不足でARPブラックホールに吸収される
- パス回復機構 (`iface_has_route_to_server`) がピン留めされた1本以外の回復を拒否する

`false` にした場合は、ルーティングを外部（NixOS networking等）で管理する必要がある。

### `init_max_path_id`

デフォルト `0` は xquic のデフォルト値 `8`（9パスまで可能）を使用する。明示的に小さな値を設定すると作成可能なパス数が制限される。

例:
- `0` → 最大9パス (path_id 0-8)
- `1` → 最大2パス (path_id 0-1)
- `4` → 最大5パス (path_id 0-4)

サーバーとクライアントの両方で設定可能だが、実質的には**サーバー側の値が上限**となる（サーバーが許可する最大path_idをクライアントが守る）。

## mqvpn-auth.json の形式

```json
{
    "server_addr": "your-server.com:443",
    "auth_key": "base64-encoded-psk..."
}
```

このファイルは `configuration.nix` の `services.mqvpn.auth` オプションから読み込まれる。**リポジトリにコミットしてはいけない**（`.gitignore` 対象）。
