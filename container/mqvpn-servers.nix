# サーバー集合の Single Source of Truth。
# idx から全派生値が決まる (name=mqvpn-server-{idx} / listen・clientPort=443+idx /
# control=9090+idx*2 / exporter=9091+idx*2 / subnet=192.168.{idx}.0/24)。
# 参照元: router/default.nix (clientPorts)、test/mogami-server.nix (FW)、
# container/mqvpn-{prometheus,grafana}-image.nix (監視)、
# container/mqvpn-compose-file.nix (compose 生成)。
# 台数変更は serverIdxs のみ (compose・監視・FW・clientPorts が連動する)。
rec {
  serverIdxs = [ 0 1 2 ];
  serverPorts = map (i: 443 + i) serverIdxs;
  serverNames = map (i: "mqvpn-server-${toString i}") serverIdxs;
}
