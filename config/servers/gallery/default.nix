{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.photoprism ];
  imports = [
    ../../profiles/hetzner-vm.nix
  ];

  deployment = {
    targetHost = "159.69.192.67";
    targetUser = "morph";
    substituteOnDestination = true;
  };

  mods.hetzner = {
    networking.ipAddresses = [
      "159.69.192.67/32"
      "2a01:4f8:c2c:2ae2::/128"
    ];
  };

  h4ck.photoprism.enable = true;

  fileSystems."/".fsType = "btrfs";
}
