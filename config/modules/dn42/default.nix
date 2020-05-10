{ config, lib, ... }:
let
  inherit (lib)
    attrValues
    concatMapStringsSep
    concatStrings
    filterAttrs
    hasAttr
    hasPrefix
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    nameValuePair
    optional
    optionalAttrs
    optionalString
    range
    types
    ;

  cfg = config.h4ck.dn42;
  wireguardKeyType = with lib; types.addCheck types.str (v: (stringLength v) > 40);
in
{
  options.h4ck.dn42 = {
    enable = mkEnableOption "enable dn42 configuration";

    bgp = mkOption {
      type = types.submodule {
        options = {
          asn = mkOption { type = types.ints.unsigned; };
          routerId = mkOption { type = types.str; };
          staticRoutes = mkOption {
            type = types.submodule {
              options = {
                ipv4 = mkOption { type = types.listOf types.str; default = []; };
                ipv6 = mkOption { type = types.listOf types.str; default = []; };
              };
            };
          };
        };
      };
    };
    peers = mkOption {
      type = (
        types.attrsOf (
          types.submodule {
            options = {
              tunnelType = mkOption {
                type = types.nullOr (types.enum [ "wireguard" ]);
                description = "tunnel technology used";
              };
              mtu = mkOption {
                type = types.nullOr types.ints.unsigned;
                default = null;
                description = "mtu on the interface";
              };
              interfaceName = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
              wireguardConfig = mkOption {
                type = types.submodule {
                  options = {
                    localPort = mkOption { type = types.ints.unsigned; };
                    remoteEndpoint = mkOption { type = types.str; };
                    remotePort = mkOption { type = types.port; };
                    remotePublicKey = mkOption { type = wireguardKeyType; };
                  };
                };
              };
              bgp = mkOption {
                type = types.submodule {
                  options = {
                    asn = mkOption { type = types.ints.unsigned; };
                    local_pref = mkOption { type = types.ints.unsigned; };
                    #export_med = mkOption { type = types.nullOr types.ints.unsigned; default = null; };
                    export_prepend = mkOption { type = types.ints.unsigned; default = 0; };
                    import_prepend = mkOption { type = types.ints.unsigned; default = 0; };
                    import_limit = mkOption { type = types.nullOr types.ints.unsigned; default = null; };

                    import_reject = mkOption { type = types.bool; default = false; };
                    export_reject = mkOption { type = types.bool; default = false; };
                    multi_protocol = mkOption { type = types.bool; default = true; };
                  };
                };
              };
              addresses = mkOption {
                type = types.submodule {
                  options = {
                    ipv6 = mkOption {
                      default = null;
                      type = types.nullOr (
                        types.submodule {
                          options = {
                            local_address = mkOption { type = types.str; };
                            remote_address = mkOption { type = types.str; };
                            prefix_length = mkOption { type = types.ints.unsigned; default = 128; };
                          };
                        }
                      );
                    };
                    ipv4 = mkOption {
                      default = null;
                      type = types.nullOr (
                        types.submodule {
                          options = {
                            local_address = mkOption { type = types.str; };
                            remote_address = mkOption { type = types.str; };
                            prefix_length = mkOption { type = types.ints.unsigned; default = 32; };
                          };
                        }
                      );
                    };
                  };
                };
              };
            };
          }
        )
      );
      default = {};
    } // {
      check = v: (if v.tunnelType == "wireguard" then hasAttr "wireguardConfig" v else true);
    };
  };

  config = let

    wireguardPeers = filterAttrs (n: v: v.tunnelType == "wireguard" && v ? wireguardConfig) cfg.peers;

    wireguardInterfaceNameMapping = mapAttrs (_: v: v.interfaceName) (filterAttrs (n: v: hasPrefix "wg-dn42_" (lib.traceVal v.interfaceName)) config.h4ck.wireguardBackbone.peers);
    wireguardInterfaceNames = attrValues wireguardInterfaceNameMapping;

    interfaceNames = lib.traceValSeq wireguardInterfaceNames;
    interfaceNameMapping = lib.traceValSeq wireguardInterfaceNameMapping;


    bgpPeers =
      lib.mapAttrsToList (
        name: v: {
          inherit name;
          interfaceName = if v.interfaceName != null then v.interfaceName else interfaceNameMapping."dn42_${name}";
          inherit (v) bgp;
        } // (
          optionalAttrs (v.addresses.ipv4 != null) {
            remoteV4 = v.addresses.ipv4.remote_address;
          }
        ) // (
          optionalAttrs (v.addresses.ipv6 != null) {
            remoteV6 = v.addresses.ipv6.remote_address;
          }
        )
      ) cfg.peers;

  in
    mkIf cfg.enable {
      h4ck.bird.enable = true;
      networking.firewall.allowedTCPPorts = [ 179 ];

      h4ck.wireguardBackbone.peers = mapAttrs' (
        name: value: nameValuePair "dn42_${name}" (
          {
            inherit (value.wireguardConfig) localPort remoteEndpoint remotePort remotePublicKey;
            remoteAddresses = (optional (value.addresses.ipv6 != null && value.addresses.ipv6 ? remote_address) value.addresses.ipv6.remote_address)
            ++ (optional (value.addresses.ipv4 != null && value.addresses.ipv4 ? remote_address) value.addresses.ipv4.remote_address);
            localAddresses = (optional (value.addresses.ipv6 != null && value.addresses.ipv6 ? local_address) "${value.addresses.ipv6.local_address}/${toString value.addresses.ipv6.prefix_length}")
            ++ (optional (value.addresses.ipv4 != null && value.addresses.ipv4 ? local_address) "${value.addresses.ipv4.local_address}/${toString value.addresses.ipv4.prefix_length}");
          } // optionalAttrs (value.mtu != null) { inherit (value) mtu; }
        )
      ) wireguardPeers;

      services.bird2.config = ''
        #
        # DN42 peering configuration
        #

        ipv4 table dn42_v4;
        ipv6 table dn42_v6;

        ${optionalString (interfaceNames != []) ''
        protocol direct dn42_direct {
          interface ${concatMapStringsSep ", " (iface: "\"${iface}\"") interfaceNames};
        }
      ''}

        protocol static dn42_static_v4 {
          ipv4 { table dn42_v4; };
          ${concatMapStringsSep "\n" (net: "route ${net} blackhole;") cfg.bgp.staticRoutes.ipv4}
        };

        protocol static dn42_static_v6 {
          ipv6 { table dn42_v6; };
          ${concatMapStringsSep "\n" (net: "route ${net} blackhole;") cfg.bgp.staticRoutes.ipv6}
        };

        function dn42_is_valid_prefix (prefix n) {
          case n.type {
            NET_IP4: if n ~ [
                     172.20.0.0/14{21,29}, # dn42
                     172.20.0.0/24{28,32}, # dn42 Anycast
                     172.21.0.0/24{28,32}, # dn42 Anycast
                     172.22.0.0/24{28,32}, # dn42 Anycast
                     172.23.0.0/24{28,32}, # dn42 Anycast
                     #172.31.0.0/16+,       # ChaosVPN
                     #10.100.0.0/14+,       # ChaosVPN
                     #10.127.0.0/16{16,32}, # neonetwork
                     10.0.0.0/8{15,24}     # Freifunk.net
                  ] then return true;
            NET_IP6: if n ~ [ fd00::/8{40,64} ] then return true;
          }
          return false;
        }

        function dn42_is_own_prefix(prefix n) {
          case n.type {
            NET_IP4: if n ~ [ ${concatMapStringsSep ",\n" (net: "${net}+") cfg.bgp.staticRoutes.ipv4} ] then return true;
            NET_IP6: if n ~ [ ${concatMapStringsSep ",\n" (net: "${net}+") cfg.bgp.staticRoutes.ipv6} ] then return true;
          }
          return false;
        }

        roa4 table dn42_roa_v4;
        roa6 table dn42_roa_v6;

        protocol pipe dn42_v4_pipe {
          peer table master4;
          table dn42_v4;
          export all;
          import none;
        }

        protocol pipe dn42_v6_pipe {
          peer table master6;
          table dn42_v6;
          export all;
          import none;
        }

        ${lib.concatMapStringsSep "\n\n" (
        peer: ''
          #
          # Peer: ${peer.name}
          # Remote ASN: ${toString peer.bgp.asn}
          #

          filter dn42_${peer.name}_import {
             ${optionalString peer.bgp.import_reject "reject;"}
             if !dn42_is_valid_prefix(net) then reject "Not a valid DN42 prefix";
             ${optionalString (peer.bgp.asn != cfg.bgp.asn)
          # eBGP isn't allowed to annouce me my own prefixes
          ''
            if dn42_is_own_prefix(net) then reject "Not accepting own prefix from eBGP peer.";
            if bgp_path ~ [= ${toString cfg.bgp.asn} * =] ||
               bgp_path ~ [= * ${toString cfg.bgp.asn} * =] ||
               bgp_path ~ [= * ${toString cfg.bgp.asn} =] then
                 reject "Not accepting paths from my own ASN via eBGP.";

            ${optionalString (peer.bgp.import_prepend != 0)
            (concatStrings (map (x: "bgp_path.prepend(${toString cfg.bgp.asn});\n") (range 0 peer.bgp.import_prepend)))}

            bgp_local_pref = ${toString peer.bgp.local_pref};

          ''}
             accept "Prefix seems okay";
          }
          filter dn42_${peer.name}_export {
            ${optionalString peer.bgp.export_reject "reject;"}
            if !dn42_is_valid_prefix(net) then reject "Not a valid DN42 prefix";
            if proto !~ "dn42_*" then reject "Prefix is not from another dn42 protocol. Rejecting.";
            ${optionalString (peer.bgp.export_prepend != 0)
          (concatStrings (map (x: "bgp_path.prepend(${toString cfg.bgp.asn});\n") (range 0 peer.bgp.export_prepend)))}

            accept "Prefix seems okay";
          }

          template bgp dn42_${peer.name}_tpl {
            local as ${toString cfg.bgp.asn};
            #import keep filtered;
            graceful restart on;
            graceful restart time 120;
            interpret communities on;
            enable extended messages on;
            enable route refresh on;
            med metric on;
            direct;

            ipv4 {
              table dn42_v4;
              igp table master4;
              add paths on;
              import filter dn42_${peer.name}_import;
              export filter dn42_${peer.name}_export;
              ${optionalString (peer.bgp.import_limit != null) "import limit ${toString peer.bgp.import_limit} action block;"}
            };
            ipv6 {
              table dn42_v6;
              igp table master6;
              add paths on;
              import filter dn42_${peer.name}_import;
              export filter dn42_${peer.name}_export;
              ${optionalString (peer.bgp.import_limit != null) "import limit ${toString peer.bgp.import_limit} action block;"}
            };
          }

          ${if peer.bgp.multi_protocol then ''
          protocol bgp dn42_${peer.name} from dn42_${peer.name}_tpl {
            #advertise ipv4 on;
            neighbor ${peer.remoteV6} as ${toString peer.bgp.asn};
            interface "${peer.interfaceName}";
            ipv6 {
              mandatory on;
            };
          }
        '' else ''
          protocol bgp dn42_${peer.name}_v4 from dn42_${peer.name}_tpl {
            neighbor ${peer.remoteV4} as ${toString peer.bgp.asn};
            interface "${peer.interfaceName}";
          }
          protocol bgp dn42_${peer.name}_v6 from dn42_${peer.name}_tpl {
            #advertise ipv4 off;
            neighbor ${peer.remoteV6} as ${toString peer.bgp.asn};
            interface "${peer.interfaceName}";
          }
        ''}
        ''
      ) bgpPeers}
      '';
    };
}
