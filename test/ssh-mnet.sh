#!/usr/bin/env bash
exec nix shell nixpkgs#sshpass nixpkgs#openssh --command sshpass -p mnet ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null digicre@192.168.50.4 "$@"