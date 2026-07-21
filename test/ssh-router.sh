#!/usr/bin/env bash
exec nix shell nixpkgs#sshpass nixpkgs#openssh --command sshpass -p router ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2223 digicre@localhost "$@"
