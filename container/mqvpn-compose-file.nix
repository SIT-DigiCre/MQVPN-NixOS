# docker-compose.yml生成 (SSOT: ./mqvpn-servers.nix)。labと実機はどちらもこの生成物を使う。
# 行指向リストで組立て (YAML字下げをnix整形から守るため)。
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
    "# !!! GENERATED — DO NOT EDIT !!! (生成元: mqvpn-compose-file.nix + mqvpn-servers.nix)"
    "# 1サーバ=1コンテナ。config共有・差分はMQVPN_INSTANCE_IDXのみ (導出式はSSOT参照)。"
    "# network_mode: hostのためidx必須。TSDB/grafana.dbはnamed volume永続化。"
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
    "    - ./mqvpn-server-conf:/etc/mqvpn:ro"
    ""
    "services:"
  ]
  ++ builtins.concatLists (map stanza servers.serverIdxs)
  ++ [
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
assert servers.serverIdxs != [ ];
pkgs.writeText "docker-compose.yml" (builtins.concatStringsSep "\n" lines + "\n")
