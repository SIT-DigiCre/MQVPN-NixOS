# OpenMQVPNRouter
MQVPNクライアントです
Router機能は未搭載

# How to Build & Run

```
# ISOイメージのビルド
nix build .#nixosConfigurations.iso.config.system.build.isoImage

# USBへの書き込み (書き込みたいデバイスを調べ、/dev/sdXを書き換える)
sudo dd if=result/iso/mqvpn-router.iso of=/dev/sdX bs=4M status=progress conv=fdatasync
```