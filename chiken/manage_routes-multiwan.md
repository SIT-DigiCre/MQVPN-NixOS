# `manage_routes = true` がマルチWANで1パスしか使えなくなる原因

## 症状

MQVPN クライアントに複数のWANインターフェースを `paths` で指定しているにもかかわらず、確立されるパスが1本だけになる。

## 原因

`setup_routes()` (`src/platform/linux/routing.c`) がマルチWAN環境に対応していない。

### 動作の流れ

1. `routing.c:97-98` — `discover_route()` が `ip route get <server>` を実行し、サーバーへの経路を**1本だけ**取得する（カーネルが選んだメトリック最小のデフォルトルート）。
2. `routing.c:110-112` — その1本だけをピン留め:
   ```
   ip route replace <server>/32 via <gateway_A> dev <iface_A>
   ```
3. `routing.c:122-125` — スプリットトンネルルートを全WAN IFに代わって挿入:
   ```
   ip route replace 0.0.0.0/1 dev mqvpn0
   ip route replace 128.0.0.0/1 dev mqvpn0
   ```

結果、ルーティングテーブルは:

```
<server>/32 via gateway_A dev iface_A   ← ピン留め（iface_A のみ）
0.0.0.0/1 dev mqvpn0
128.0.0.0/1 dev mqvpn0
default via gateway_A dev iface_A       ← 元のデフォルト
default via gateway_B dev iface_B       ← 元のデフォルト（残存はしている）
```

### FIBエントリがないためパスが回復できない

`route_check.c` の `iface_has_route_to_server()` は `RTM_F_FIB_MATCH` フラグ付きの `RTM_GETROUTE` で「指定したインターフェースにサーバー宛のFIBエントリが存在するか」を厳密に判定する。

iface_B 〜 iface_E には `<server>` 宛の FIB エントリが存在しないため、この関数は `0` を返す。

このチェックがパス回復をブロックする箇所:

| 場所 | 影響 |
|------|------|
| `netlink_mon.c:200` (`try_reactivate_by_ifname`) | リアクティベートを拒否 |
| `netlink_mon.c:410` (`try_readd_removed_path`) | パスの再追加を拒否 |
| `netlink_mon.c:521` (`recover_dropped_paths_cb`) | `"no route to the server — re-add deferred"` のログ + スキップ |

一度でもパスがドロップされたり活性化に失敗したりすると、ピン留めされた1本以外は永遠に回復できない。

### 初回パス作成時のタイミング問題

`cb_tunnel_config_ready` → `setup_routes()` が `cb_ready_to_create_path` → `activate_pending_paths()` より先に走った場合、ルートがない状態でパス活性化が試行される。`SO_BINDTODEVICE` されたソケットは `sendto()` が成功しても、カーネルの "assume on-link" フォールバックにより ARP ブラックホールに吸収される（`route_check.c:8-16` のコメント参照）。

### 参考: `iface_has_route_to_server()` のコメント原文

```
Why RTM_F_FIB_MATCH and not a plain output-route lookup: for
oif-bound lookups (our path sockets are SO_BINDTODEVICE) the kernel
falls back to "Apparently, routing tables are wrong. Assume, that
the destination is on link" (net/ipv4/route.c) when no FIB entry
matches — the lookup SUCCEEDS, sendto() succeeds, and the packet is
silently ARP-blackholed on the local LAN. RTM_F_FIB_MATCH asks for
the matching FIB entry itself; the fallback synthesizes a route
with res->fi == NULL, so the fibmatch query fails with
ENETUNREACH/EHOSTUNREACH exactly when no real route (gateway OR
genuine on-link) exists through this interface.
```

## 修正案

`configuration.nix` で生成する mqvpn.conf に `manage_routes = false` を追加し、MQVPN によるルーティング操作を無効化する:

```nix
mqvpnConfig = pkgs.writeText "mqvpn.conf" (builtins.toJSON ({
    mode = "client";
    manage_routes = false;
    # ... 既存の設定
  } // mqvpnAuth));
```

### 効果

- `setup_routes()` が呼ばれなくなる（`platform_linux.c:134` のガード）
- 各 WAN IF のデフォルトルートが維持される
- `SO_BINDTODEVICE` された各ソケットが各 IF のデフォルトゲートウェイ経由でサーバーに到達できる
- `iface_has_route_to_server()` が全 IF で `1` を返すようになる

### 注意点

`manage_routes = false` にすると MQVPN は以下を実行しなくなる:
- `<server>/32` のピン留め
- `0.0.0.0/1 + 128.0.0.0/1` のトンネル経由ルート設定
- IPv6 `::/1 + 8000::/1` のトンネル経由ルート設定

TUN インターフェース自体は作成・IPアドレス設定・UPまでは行われるが、デフォルトルートをトンネルに向ける処理がスキップされる。ルーティングは NixOS の networking または外部の仕組みで行う必要がある。
