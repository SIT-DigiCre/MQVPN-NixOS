# docker-compose.yml 生成 (サーバー台帳の SSOT: ./mqvpn-servers.nix)。
# lab (test/mogami-server.nix の composeDir) と実機デプロイ
# (docs/howto-server.md) はどちらもこの生成物を使う。手書き compose は持たない。
# 行指向の文字列リストで組み立てる (YAML の字下げを nix の整形から守るため)。
{ pkgs }:
let
  servers = import ./mqvpn-servers.nix;
  stanza = i: [
    "  mqvpn-server-${toString i}:"
    "    <<: *mqvpn-server"
    "    container_name: mqvpn-server-${toString i}"
    "    environment:"
    "      - MQVPN_INSTANCE_IDX=${toString i}"
    ""
  ];
  lines = [
    "# !!! GENERATED — DO NOT EDIT !!! (生成元: container/mqvpn-compose-file.nix + mqvpn-servers.nix)"
    "# 台数変更は serverIdxs を変えて本ファイルを再生成すること。"
    "# 1 サーバ = 1 コンテナ。config は全インスタンスで同一ファイルをマウントし、"
    "# 差分は MQVPN_INSTANCE_IDX のみ (残りはエントリポイントが自動導出:"
    "# tun=mqvpn<idx>, listen=0.0.0.0:(443+idx), control=127.0.0.1:(9090+idx*2),"
    "# exporter=(9091+idx*2), subnet=192.168.<idx>.0/24)。"
    "# network_mode: host のため idx は必須 (コンテナ名から取れない)。"
    "# 監視: prometheus=127.0.0.1:9000 / grafana=:3000(admin/admin、初回変更)。"
    "# TSDB/grafana.db は named volume 永続化。"
    ""
    "x-mqvpn-server: &mqvpn-server"
    "  image: mqvpn-server:latest"
    "  restart: unless-stopped"
    "  network_mode: host"
    "  devices:"
    "    - /dev/net/tun:/dev/net/tun"
    "  cap_drop:"
    "    - ALL"
    "  cap_add:"
    "    - NET_ADMIN"
    "    - NET_BIND_SERVICE"
    "  volumes:"
    "    # 共有 server.conf (hybrid=off) + インスタンスごとに MQVPN_* env で差分"
    "    - ./mqvpn-server-conf:/etc/mqvpn:ro"
    ""
    "services:"
  ] ++ builtins.concatLists (map stanza servers.serverIdxs) ++ [
    "  prometheus:"
    "    image: mqvpn-prometheus:latest"
    "    container_name: prometheus"
    "    restart: unless-stopped"
    "    network_mode: host"
    "    volumes:"
    "      - prometheus-data:/prometheus"
    ""
    "  grafana:"
    "    image: mqvpn-grafana:latest"
    "    container_name: grafana"
    "    restart: unless-stopped"
    "    network_mode: host"
    "    volumes:"
    "      - grafana-data:/var/lib/grafana"
    "    environment:"
    "      # 初回ログイン時に必ず変更すること。"
    "      - GF_SECURITY_ADMIN_PASSWORD=admin"
    "      - GF_USERS_ALLOW_SIGN_UP=false"
    "      - GF_PATHS_PROVISIONING=/etc/grafana/provisioning"
    "      - GF_SERVER_HTTP_ADDR=127.0.0.1"
    ""
    "volumes:"
    "  prometheus-data: {}"
    "  grafana-data: {}"
  ];
in
assert servers.serverIdxs != [];
pkgs.writeText "docker-compose.yml" (builtins.concatStringsSep "\n" lines + "\n")
