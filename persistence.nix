{
  # ---------------------------------------------------------------------
  # Ephemeral Root (Impermanence) & Btrfs Rollback
  # ---------------------------------------------------------------------
  boot.initrd.systemd.enable = true;

  boot.initrd.systemd.services.rollback = {
    description = "Rollback Btrfs root subvolume";
    wantedBy = [ "initrd.target" ];
    after = [ "disk-by\\x2dlabel-nixos_root.device" ];
    before = [ "sysroot.mount" ];
    conflicts = [ "initrd-switch-root.target" ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      while [ ! -e /dev/disk/by-label/nixos_root ]; do
        sleep 0.1
      done
      mkdir -p /mnt
      mount -t btrfs -o subvolid=5 /dev/disk/by-label/nixos_root /mnt

      if [ -e /mnt/root ]; then
        btrfs subvolume delete /mnt/root
      fi

      btrfs subvolume create /mnt/root

      umount /mnt
    '';
  };

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/lib/systemd/timers"
      "/var/lib/nixos"
      "/var/log"
      "/var/lib/NetworkManager"
      {
        directory = "/var/lib/kea";
        user = "kea";
        group = "kea";
        mode = "0755";
      }
      "/etc/ssh"
      "/etc/nixos"
    ];
    files = [
      "/etc/machine-id"
    ];
  };
}
