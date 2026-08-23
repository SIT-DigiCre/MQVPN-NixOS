#!/usr/bin/env bash
exec nix shell nixpkgs#sshpass nixpkgs#openssh --command sshpass -p test ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null testuser@192.168.50.3 "$@"
