# サーバー集合のSSOT: name=mqvpn-server-{idx} / listen=443+idx /
# control=9090+idx*2 / exporter=9091+idx*2 / subnet=192.168.{idx}.0/24。
# 台数変更はserverIdxsのみ (compose・監視・FW・clientPortsが連動)。
rec {
  serverIdxs = [
    0
    1
    2
  ];
  serverPorts = map (i: 443 + i) serverIdxs;
  serverNames = map (i: "mqvpn-server-${toString i}") serverIdxs;
}
