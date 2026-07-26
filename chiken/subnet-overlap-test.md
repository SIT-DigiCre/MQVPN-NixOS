# サブネット重複テスト: WAN サブネットと MQVPN トンネルサブネットの衝突

## 結論

MQVPN は WAN 物理 IF のサブネットと TUN トンネルのサブネットが完全に一致していても**問題なく動作する**。

## 実験設定

テスト環境 (`test/`) の WAN 側サブネットを MQVPN トンネルサブネットと同じ `192.168.0.0/24` に変更。

| レイヤ | 通常 | 実験 |
|--------|------|------|
| WAN (Router↔Server) | `10.200.0.0/24` | `192.168.0.0/24` |
| MQVPN tunnel | `192.168.0.0/24` | `192.168.0.0/24` (同じ!) |

## ルーター上の経路表 (重複時)

```
192.168.0.0/24 dev eth2  scope link src 192.168.0.2   ← WAN 直接経路
192.168.0.0/24 dev eth4  scope link src 192.168.0.3   ← WAN 直接経路
192.168.0.0/24 dev eth5  scope link src 192.168.0.4   ← WAN 直接経路
192.168.0.0/24 dev eth6  scope link src 192.168.0.5   ← WAN 直接経路
192.168.0.0/24 dev eth7  scope link src 192.168.0.6   ← WAN 直接経路
192.168.0.1 dev mqvpn0   scope link src 192.168.0.2   ← TUN peer 経路 (/32)
```

`192.168.0.1` への /32 経路が TUN 経由で存在している。

## なぜ動くのか

### 外側 QUIC パケットの経路選択

MQVPN の各 socket は `SO_BINDTODEVICE(eth<N>)` で物理 WAN IF にバインドされている。Linux カーネルの FIB (Forwarding Information Base) は、`SO_BINDTODEVICE` により socket が束縛された IF 経由の経路のみをルックアップ対象とする。

```
送信先: 192.168.0.1:443
socket 束縛: eth2

FIB ルックアップ結果 (束縛 IF = eth2):
  - 192.168.0.0/24 dev eth2  scope link  → IF 一致  ✓
  - 192.168.0.0/24 dev eth4  scope link  → IF 不一致 ✗
  - 192.168.0.1 dev mqvpn0   scope link  → IF 不一致 ✗

→ 192.168.0.0/24 dev eth2 を選択 → eth2 から送出
```

`SO_BINDTODEVICE` が **TUN 経由の /32 経路を自動的に除外する** ため、外側 QUIC パケットは常に正しい物理 WAN IF から出ていく。

### 内側パケット（トンネル通過後）の経路選択

LAN クライアントからのトラフィックは MQVPN で復号され、`mqvpn0` からカーネルに注入される。

```
パケット注入: mqvpn0 (inner)
送信先: 9.9.9.9

FIB ルックアップ (束縛なし):
  0.0.0.0/1 dev mqvpn0 scope link  → MQVPN のスプリットトンネル経路に一致
  → 再度 MQVPN プロセスへ (暗号化 → 外側 QUIC として WAN IF から送出)
```

内側パケットは MQVPN の `manage_routes` が追加したスプリットトンネル経路 (`0.0.0.0/1`, `128.0.0.0/1`) にマッチし、物理 IF を直接使わずに MQVPN に戻る。

### 物理世界とトンネル世界の分離

```
外側パケット:  src=eth2(WAN IP) → dst=192.168.0.1:443
               SO_BINDTODEVICE により IF 単位で経路解決
               このパケットは mqvpn0 を通らない

内側パケット:  src=172.16.0.x(LAN) → dst=9.9.9.9
               mqvpn0 のルーティングテーブルで経路解決
               このパケットは物理 WAN IF を直接使わない
```

これらは Linux カーネルのネットワークスタック内で **完全に独立したレイヤー** として動作するため、サブネットが重複しても衝突しない。

## 実機 (CPE あり) の場合

実機では各 CPE ルーターがゲートウェイとなるため、MQVPN の `manage_routes` がサーバーピン経路を追加する:

```
ip route replace 192.168.0.1 via <CPEのIP> dev enp12s0f1
```

非バインドトラフィック（`curl`、`ping` 等）の経路も WAN IF 経由に矯正される。`SO_BINDTODEVICE` + サーバーピン経路の二重の防御により、実機でも問題は起きない。

## 他の VPN との比較

| VPN | サブネット重複の影響 | 理由 |
|-----|---------------------|------|
| **MQVPN** | 問題なし | `SO_BINDTODEVICE` で外側パケットの経路が物理 IF に固定される |
| **OpenVPN** | ルーティングループで死ぬ | `ip route` ベースの経路追加のみで、ソケット束縛がない |
| **WireGuard** | 意図しない経路選択が発生 | `AllowedIPs` によるルート追加が物理側と衝突 |
| **Tailscale/ZeroTier** | 問題なし | わざと被らないレンジ (`100.x.x.x` 等) を使う設計 |
