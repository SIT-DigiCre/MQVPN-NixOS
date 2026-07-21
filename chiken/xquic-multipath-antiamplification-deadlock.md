# xquic マルチパス anti-amplification デッドロック

## 症状

MQVPN クライアントに複数の `paths` を指定しても、path0（初期パス）のみが ACTIVE になる。
セカンダリパスは VALIDATING → XQUIC_REMOVED → CLOSED_RECOVERABLE → retry を繰り返し、ACTIVE にならない。

## サーバーログの証拠

```
blocked by anti amplification limit|total_sent:3636|3*total_recv:3600|
```

## 原因

**xquic の anti-amplification limit が per-path で適用されていることが原因。**

QUIC RFC 9000 の anti-amplification は、サーバーが未検証のアドレスに対して
3× 以上のデータを送信することを禁止する。xquic はこれをパスごとに独立して
適用している。

### 問題のコード

`mp0rta/xquic/src/transport/xqc_send_ctl.c:1986-2016`:

```c
xqc_bool_t
xqc_send_ctl_check_anti_amplification(xqc_send_ctl_t *send_ctl, size_t send_bytes)
{
    xqc_connection_t *conn = send_ctl->ctl_conn;
    xqc_path_ctx_t *path = send_ctl->ctl_path;

    xqc_bool_t limit = XQC_FALSE;
    xqc_bool_t check = XQC_FALSE;

    if (conn->conn_type == XQC_CONN_TYPE_SERVER && send_ctl->ctl_bytes_send > 0) {
        if (xqc_path_is_initial_path(path)) {
            /* initial path => ハンドシェイク完了で解除 */
            if (!(conn->conn_flag & XQC_CONN_FLAG_ADDR_VALIDATED)) {
                check = XQC_TRUE;
            }
        } else {
            /* multipath => ACTIVE になるまで常時チェック */
            if (path->path_state < XQC_PATH_STATE_ACTIVE) {
                check = XQC_TRUE;
            }
        }
    }

    if (check) {
        limit = (send_ctl->ctl_bytes_send + send_bytes
                >= conn->conn_settings.anti_amplification_limit * send_ctl->ctl_bytes_recv);
    }
    return limit;
}
```

### 初期パスとマルチパスの差異

| パス | チェック条件 | 解除条件 |
|------|------------|---------|
| path0 (初期) | `!ADDR_VALIDATED` | ハンドシェイク完了 = 1-RTT到達 |
| path1-4 (マルチ) | `path_state < ACTIVE` | PATH_RESPONSE 受信 = path_state→ACTIVE |

### デッドロックの流れ

```
1. Client → Server: PATH_CHALLENGE (1200B)   [path1-4それぞれ]
   Server ctl_bytes_recv += 1200

2. Server → Client: PATH_CHALLENGE (1200B) + PATH_RESPONSE (1200B)
   Server ctl_bytes_send += 2400
   3 × 1200 = 3600 > 2400 → OK（初回は通る）

3. Client PTO → PATH_CHALLENGE 再送 (1200B)
   Server ctl_bytes_recv += 1200 → 合計 2400 のはずが...

   enc_size には TLS AEAD タグ(16B/Nパケット)やパディングが含まれる
   実際: total_sent=3636, 3×total_recv=3600 → BLOCKED!

4. Server の PATH_RESPONSE 送信が止まる
   → Client は PATH_RESPONSE を受信できない
   → path_challenge_attempts が上限(3回)に達する
   → XQC_PATH_VALIDATION_MAX_ATTEMPTS = 3
   → xqc_path_request_abandon() → path 削除
```

### なぜ Path0 だけ動くのか

初期パスは `conn->conn_flag & XQC_CONN_FLAG_ADDR_VALIDATED` で制限が解除される。
このフラグはハンドシェイク完了時に立つ。

マルチパスのセカンダリパスは `path_state < XQC_PATH_STATE_ACTIVE` でチェックされる。
ACTIVE になるには PATH_RESPONSE 受信が必要だが、その PATH_RESPONSE 送信が
anti-amplification limit でブロックされる → **鶏卵問題**。

## 影響範囲

- MQVPN v0.13.1 に同梱の xquic で発生確認
- 実サーバーでもサーバーVMでも同一挙動（原因が NAT か anti-amplification かの違いだけで根本は同じ）
- Issue #184 と関連あり（同根の可能性）

## Upstream での状況

- alibaba/xquic には anti-amplification 関連の Issue が存在する (#775, #736, #562) が、**マルチパス特化のこのデッドロックを報告した Issue は見当たらない**
- `mp0rta/xquic`（mqvpn の xquic フォーク）でも同様
- 本件のパッチ (`patches/xquic-antiamp-fix.patch`) は、接続レベルの `ADDR_VALIDATED` フラグをマルチパス分岐でも参照するようにする修正（上記 修正案1 を実装）

## 考えられる修正案

1. **接続レベルの anti-amplification に変更**: 初期パスでアドレス検証済みなら全パスの制限を解除する
2. **PATH_CHALLENGE/PATH_RESPONSE を limit 計算から除外**: 制御フレームは free にする
3. **VALIDAING 中のパスには最低 1 回の PATH_RESPONSE 送信を許可**: limit 超過時も例外扱い
4. **`anti_amplification_limit` を大きくする**: 3 → 10 など（暫定対処）
