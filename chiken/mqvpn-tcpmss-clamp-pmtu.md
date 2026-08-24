# TCPMSS clamp ルールの妥当性調査 (PMTU ブラックホールは起きるか)

> 更新: 2026-08-25。ラボ (mogami-vm ルーター / mogami-server / mogami-client / mogami-mnet)、iperf3 TCP 単一フロー、client↔mnet(192.168.100.1) 経路。

## 対象

`configuration.nix` の `networking.firewall.extraCommands` が FORWARD mangle に仕掛ける:

```
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

トンネル MTU は 1382 (mqvpn0/1)。コメントの主張は「MTU より大きいセグメントで PMTU ブラックホール(再送地獄)になり、clamp で単一 TCP フローが 5x 改善した」。

## 結論

**このラボ環境では、ルールがなくても PMTU ブラックホールは起きない。** clamp の実効益は「トンネル内 IP フラグメンテーションの回避」による数割の改善であり、コメントの「5x / 再送地獄」は過大評価（SLiRP 等 ICMP が本当に戻らない環境向けの話）。

## 計測 (clamp あり/なし)

| 方向 | clamp | スループット | mnet 送信 MSS | 備考 |
|---|---|---|---|---|
| DOWN (-R) | ON  | 732 Mbps | 1330 | MSS が 1448→1330 に削られる (clamp 動作) |
| DOWN (-R) | OFF | 664 Mbps | 1448 | 崩壊せず。約 10% 低下のみ |
| UP       | OFF | ~1.3 Gbps | — | UP のクライアント送信 MSS は mnet 広告値依存で clamp の影響外 |

clamp なしでもスループットは高く、致命的な再送地獄は観測されない。

## なぜ「なし」で崩壊しないか

**トンネル端点が内側パケットをローカル断片化して運ぶため、mnet には frag-needed が届かない。**

DOWN フロー (clamp なし) 中に mnet で確認:
- `InType3` (ICMP Destination Unreachable / frag-needed 受信) = **0** (流している最中も 0→0)
- `ip tcp_metrics show 172.16.0.50` (client) = **none** (PMTU 未学習)
- スループットは高い (976 Mbps) → ブラックホールではなく、断片化で通っている

つまり mqvpn サーバーコンテナが、mnet からの 1448 バイト超セグメントを「mnet へ ICMP frag-needed を返す」のではなく「トンネル内で断片化して運ぶ」(VPN の典型的な DF クリア/ローカル断片化)。そのため mnet は MSS を縮めず 1448 のまま送り続け、トンネル内で IP フラグメント化される。これが数割のコスト（ヘッダオーバーヘッド + フラグメント片欠損による再送）の正体。

非対称: client (UP 送信側) にはルーターが LAN 越しに直接 ICMP frag-needed を返せるので cache `mtu 1382` に学習されるが、mnet (DOWN 送信側) にはトンネル端点が信号を出さないので学習されない。

## ルールの扱い

- この環境では「ブラックホール防止の必須要件」ではない。
- 残しても良いが、残すなら「トンネル内フラグメント回避（数割の改善）」と注記すべき。SLiRP 系では ICMP が戻らず完全ブラックホールになるので、そういう環境向けの保険としては有用。
- コメントは `configuration.nix` 側を簡潔な記述に書き直し済み。
