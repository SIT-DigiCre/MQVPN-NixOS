# OpenMQVPNRouter
MQVPNクライアントです

# How to Build & Run

## ISOイメージのビルド
`nix build path:.#nixosConfigurations.iso.config.system.build.isoImage`

## USBメモリへの書き込み
`sudo dd if=result/iso/mqvpn-router.iso of=/dev/<デバイス名> bs=4M status=progress conv=fdatasync`

## SSDへの書き込み
`sudo ./writer.sh /dev/<デバイス名>`
