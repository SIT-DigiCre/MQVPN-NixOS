{ ... }:
{
  imports = [
    ./base.nix
    ./network.nix
    ./mqvpn.nix
  ];

  networking.hostName = "mogami";

  services.mqvpn = {
    interfaces = [
      "enp1s0f0"
      "enp1s0f1"
      "enp1s0f2"
      "enp1s0f3"
      "enp6s0"
      "enp8s0"
      "enp9s0"
    ];
    auth = builtins.fromJSON (builtins.readFile ../mqvpn-auth.json);
    clientPorts = [
      443
      444
      445
    ];
    cc = "bbr";
    lanInterface = "enp10s0";
    hybrid = {
      enabled = false;
      tcp = "auto";
      tcp_max_flows = 2048;
    };
    reorder = {
      enabled = "on";
      max_wait_ms = 100;
      cap_packets = 4096;
    };
  };
}
