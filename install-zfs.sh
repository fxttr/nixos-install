#!/usr/bin/env bash

set -euo pipefail

export COLOR_RESET="\033[0m"
export RED_BG="\033[41m"
export BLUE_BG="\033[44m"
export DISK=$1
export HOSTNAME=$2
export ZFS_POOL="rpool"

function err {
    echo -e "${RED_BG}$1${COLOR_RESET}"
}

function info {
    echo -e "${BLUE_BG}$1${COLOR_RESET}"
}

if [[ "$EUID" > 0 ]]; then
    err "Must run as root"
    exit 1
fi

if ! [[ -v DISK ]]; then
    err "Missing argument. Expected block device name, e.g. 'sda'"
    exit 1
fi

if ! [[ -v HOSTNAME ]]; then
    err "Missing argument. Expected hostname, e.g. 'nixos'"
    exit 1
fi

export DISK_PATH="/dev/${DISK}"

if ! [[ -b "$DISK_PATH" ]]; then
    err "Invalid argument: '${DISK_PATH}' is not a block special file"
    exit 1
fi

# ephemeral datasets
export ZFS_LOCAL="${ZFS_POOL}/local"
export ZFS_DS_ROOT="${ZFS_LOCAL}/root"
export ZFS_DS_NIX="${ZFS_LOCAL}/nix"

# persistent datasets
export ZFS_SAFE="${ZFS_POOL}/safe"
export ZFS_DS_HOME="${ZFS_SAFE}/home"
export ZFS_DS_PERSIST="${ZFS_SAFE}/persist"

export ZFS_BLANK_SNAPSHOT="${ZFS_DS_ROOT}@blank"

info "Running the UEFI (GPT) partitioning and formatting directions from the NixOS manual ..."
parted "$DISK_PATH" -- mklabel gpt
parted "$DISK_PATH" -- mkpart primary 512MiB 100%
parted "$DISK_PATH" -- mkpart ESP fat32 1MiB 512MiB
parted "$DISK_PATH" -- set 2 boot on
export DISK_PART_ROOT="${DISK_PATH}1"
export DISK_PART_BOOT="${DISK_PATH}2"

info "Formatting boot partition ..."
mkfs.fat -F 32 -n boot "$DISK_PART_BOOT"

info "Creating '$ZFS_POOL' ZFS pool for '$DISK_PART_ROOT' ..."
zpool create -o ashift=13 -o atime=off -o xattr=sa -o compression=lz4 -f "$ZFS_POOL" "$DISK_PART_ROOT"

#info "Enabling compression for '$ZFS_POOL' ZFS pool ..."
#zfs set compression=on "$ZFS_POOL"

info "Creating '$ZFS_DS_ROOT' ZFS dataset ..."
zfs create -p -o mountpoint=legacy "$ZFS_DS_ROOT"

info "Configuring extended attributes setting for '$ZFS_DS_ROOT' ZFS dataset ..."
zfs set xattr=sa "$ZFS_DS_ROOT"

info "Configuring access control list setting for '$ZFS_DS_ROOT' ZFS dataset ..."
zfs set acltype=posixacl "$ZFS_DS_ROOT"

info "Creating '$ZFS_BLANK_SNAPSHOT' ZFS snapshot ..."
zfs snapshot "$ZFS_BLANK_SNAPSHOT"

info "Mounting '$ZFS_DS_ROOT' to /mnt ..."
mount -t zfs "$ZFS_DS_ROOT" /mnt

info "Mounting '$DISK_PART_BOOT' to /mnt/boot ..."
mkdir /mnt/boot
mount -t vfat "$DISK_PART_BOOT" /mnt/boot

info "Creating '$ZFS_DS_NIX' ZFS dataset ..."
zfs create -p -o mountpoint=legacy "$ZFS_DS_NIX"

info "Disabling access time setting for '$ZFS_DS_NIX' ZFS dataset ..."
zfs set atime=off "$ZFS_DS_NIX"

info "Mounting '$ZFS_DS_NIX' to /mnt/nix ..."
mkdir /mnt/nix
mount -t zfs "$ZFS_DS_NIX" /mnt/nix

info "Creating '$ZFS_DS_HOME' ZFS dataset ..."
zfs create -p -o mountpoint=legacy "$ZFS_DS_HOME"

info "Mounting '$ZFS_DS_HOME' to /mnt/home ..."
mkdir /mnt/home
mount -t zfs "$ZFS_DS_HOME" /mnt/home

info "Creating '$ZFS_DS_PERSIST' ZFS dataset ..."
zfs create -p -o mountpoint=legacy "$ZFS_DS_PERSIST"

info "Mounting '$ZFS_DS_PERSIST' to /mnt/persist ..."
mkdir /mnt/persist
mount -t zfs "$ZFS_DS_PERSIST" /mnt/persist

info "Permit ZFS auto-snapshots on ${ZFS_SAFE}/* datasets ..."
zfs set com.sun:auto-snapshot=true "$ZFS_DS_HOME"
zfs set com.sun:auto-snapshot=true "$ZFS_DS_PERSIST"

info "Creating persistent directory for host SSH keys ..."
mkdir -p /mnt/persist/etc/ssh

info "Generating NixOS configuration (/mnt/etc/nixos/*.nix) ..."
nixos-generate-config --root /mnt

info "Enter password for the root user ..."
ROOT_PASSWORD_HASH="$(mkpasswd -m sha-512 | sed 's/\$/\\$/g')"

info "Enter personal user name ..."
read USER_NAME

info "Enter password for '${USER_NAME}' user ..."
USER_PASSWORD_HASH="$(mkpasswd -m sha-512 | sed 's/\$/\\$/g')"

info "Moving generated hardware-configuration.nix to /persist/etc/nixos/ ..."
mkdir -p /mnt/persist/etc/nixos
mv /mnt/etc/nixos/hardware-configuration.nix /mnt/persist/etc/nixos/

info "Writing NixOS configuration to /persist/etc/nixos/ ..."
cat <<EOF > /mnt/persist/etc/nixos/configuration.nix
{ config, pkgs, lib, ... }:
{
  imports =
    [ 
      ./hardware-configuration.nix
    ];

  nix.nixPath =
    [
      "nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos"
      "nixos-config=/persist/etc/nixos/configuration.nix"
      "/nix/var/nix/profiles/per-user/root/channels"
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    zfs rollback -r ${ZFS_BLANK_SNAPSHOT}
  '';

  boot.kernelParams = [ "elevator=none" ];
  networking.hostId = "$(head -c 8 /etc/machine-id)";
  networking.useDHCP = true;
   nix.extraOptions = lib.optionalString (config.nix.package == pkgs.nixFlakes)
      "experimental-features = nix-command flakes";

  networking.hostName = "${HOSTNAME}";
  environment.systemPackages = with pkgs;
    [
      vim
      htop
      git
      home-manager
    ];

  programs.zsh = {
    enable = true;
  };

  services.zfs = {
    autoScrub.enable = true;
    autoSnapshot.enable = true;
    # TODO: autoReplication
  };

  services.openssh = {
    enable = true;
    permitRootLogin = "yes";
    passwordAuthentication = true;
    hostKeys =
      [
        {
          path = "/persist/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
        {
          path = "/persist/etc/ssh/ssh_host_rsa_key";
          type = "rsa";
          bits = 4096;
        }
      ];
  };
  
  users = {
    mutableUsers = false;
    users = {
      root = {
        initialHashedPassword = "${ROOT_PASSWORD_HASH}";
      };

      ${USER_NAME} = {
        createHome = true;
	      isNormalUser = true;
        initialHashedPassword = "${USER_PASSWORD_HASH}";
	      extraGroups = [ "wheel" ];
	      group = "users";
	      uid = 1000;
	      home = "/home/${USER_NAME}";
	      shell = pkgs.zsh;

        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDIf72dv444ALp/SZ2zkWJjOboAjyQJA3FGJsr/ADPFO"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJQSkwfJHE6SA4otYljLI2kVlQxt3aLhHrjKLcZAmul"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBwXdh/VnT5KGFoQcq2rXiKVXPLMcPLxN6HAZqaIptTI"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvRD94isYVWqQIL9b9aP+mZiIBhJkMVPU3744C+NjD6"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFBOAvFL34WZRnKtwMx27zAXq4Z8vQxK8oR+O+6UYwet eddsa-key-20221216"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOCbnpc2pnr/wk64fHe+nI3ydgk6umjHflT8vkN6IPHL fb@fx-ttr.de"
        ];
      };
    };
  };
  system.stateVersion = "23.11"; # Did you read the comment?
}
EOF

info "Installing NixOS to /mnt ..."
rm -rf /mnt/etc/nixos/configuration.nix
ln -s /mnt/persist/etc/nixos/configuration.nix /mnt/etc/nixos/configuration.nix
nixos-install -I "nixos-config=/mnt/persist/etc/nixos/configuration.nix" --no-root-passwd  # already prompted for and configured password
