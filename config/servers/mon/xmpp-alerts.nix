{ config, lib, pkgs, ... }:
let
  config = pkgs.writeText "config.yaml" (builtins.toJSON {
    jid = "prometheus@kack.it";
    listen_address = "127.0.0.1";
    listen_port = 9199;
    password_command = "cat /var/lib/secrets/prometheus-xmpp-alerts.password";
    to_jid = "andi@kack.it";
    amtool_allowed = [];
    format = "full";
  });
in {
  systemd.services.prometheus-xmpp-alerts = {
    script = ''
      exec ${pkgs.prometheus-xmpp-alerts}/bin/prometheus-xmpp-alerts --config ${config}
    '';
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    serviceConfig.DynamicUser = true;
  };
}
