{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        # diskoによって自動で(与えた引数に)置き換えられるので変更しなくて問題ない
        device = "/dev/changeme";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "2G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap = {
              size = "8G";
              content = {
                type = "swap";
                discardPolicy = "both";
                resumeDevice = true;
              };
            };
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [
                  "-f"
                  "-L"
                  "nixos_root"
                ];
                subvolumes =
                  let
                    btrfsOpts = [
                      "compress-force=zstd"
                      "noatime"
                    ];
                  in
                  {
                    "root" = {
                      mountpoint = "/";
                    };
                    "nix" = {
                      mountpoint = "/nix";
                      mountOptions = btrfsOpts;
                    };
                    "persist" = {
                      mountpoint = "/persist";
                      mountOptions = btrfsOpts;
                    };
                  };
              };
            };
          };
        };
      };
    };
  };

  fileSystems."/persist".neededForBoot = true;
}
