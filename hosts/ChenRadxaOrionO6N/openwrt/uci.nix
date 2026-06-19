{ lib }:

let
  mkScalar = name: value: {
    kind = "option";
    inherit name value;
  };

  mkList = name: values: {
    kind = "list";
    inherit name values;
  };

  renderValue =
    value:
    if builtins.isString value then
      "'${value}'"
    else if builtins.isInt value then
      "'${toString value}'"
    else
      throw "Unsupported UCI value type";

  renderEntry =
    entry:
    if entry.kind == "option" then
      "\toption ${entry.name} ${renderValue entry.value}"
    else if entry.kind == "list" then
      lib.concatMapStringsSep "\n" (value: "\tlist ${entry.name} ${renderValue value}") entry.values
    else
      throw "Unsupported UCI entry kind";

  renderSection =
    section:
    let
      header =
        if section.name == null then
          "config ${section.type}"
        else
          "config ${section.type} '${section.name}'";
    in
    lib.concatStringsSep "\n" ([ header ] ++ map renderEntry section.entries);

  renderFile = sections: lib.concatStringsSep "\n\n" (map renderSection sections) + "\n";

  files = {
    system = renderFile [
      {
        type = "system";
        name = null;
        entries = [
          (mkScalar "hostname" "OpenWrt")
          (mkScalar "timezone" "CST-8")
          (mkScalar "ttylogin" 0)
          (mkScalar "log_size" 64)
          (mkScalar "urandom_seed" 0)
          (mkScalar "zonename" "Asia/Shanghai")
          (mkScalar "log_proto" "udp")
          (mkScalar "conloglevel" 8)
          (mkScalar "cronloglevel" 5)
        ];
      }
      {
        type = "timeserver";
        name = "ntp";
        entries = [
          (mkList "server" [
            "0.openwrt.pool.ntp.org"
            "1.openwrt.pool.ntp.org"
            "2.openwrt.pool.ntp.org"
            "3.openwrt.pool.ntp.org"
          ])
        ];
      }
    ];

    network = renderFile [
      {
        type = "interface";
        name = "loopback";
        entries = [
          (mkScalar "device" "lo")
          (mkScalar "proto" "static")
          (mkScalar "ipaddr" "127.0.0.1")
          (mkScalar "netmask" "255.0.0.0")
        ];
      }
      {
        type = "globals";
        name = "globals";
        entries = [
          (mkScalar "ula_prefix" "fd77:58a4:e94e::/48")
          (mkScalar "packet_steering" "1")
        ];
      }
      {
        type = "device";
        name = null;
        entries = [
          (mkScalar "name" "br-lan")
          (mkScalar "type" "bridge")
          (mkList "ports" [ "eth0" ])
        ];
      }
      {
        type = "interface";
        name = "lan";
        entries = [
          (mkScalar "device" "br-lan")
          (mkScalar "proto" "static")
          (mkScalar "ipaddr" "192.168.33.1")
          (mkScalar "netmask" "255.255.255.0")
          (mkList "dns" [ "223.5.5.5" "114.114.114.114" ])
        ];
      }
      {
        type = "interface";
        name = "wan";
        entries = [
          (mkScalar "device" "eth1")
          (mkScalar "proto" "pppoe")
          (mkScalar "username" "@@OWRT_SECRET:WAN_PPPOE_USERNAME@@")
          (mkScalar "password" "@@OWRT_SECRET:WAN_PPPOE_PASSWORD@@")
          (mkScalar "ipv6" "auto")
          (mkList "ip6class" [ "local" ])
        ];
      }
      {
        type = "interface";
        name = "wan6";
        entries = [
          (mkScalar "device" "eth1")
          (mkScalar "proto" "dhcpv6")
        ];
      }
      {
        type = "device";
        name = null;
        entries = [
          (mkScalar "name" "eth1")
          (mkScalar "macaddr" "88:C3:97:9B:92:03")
        ];
      }
      {
        type = "interface";
        name = "vamrs";
        entries = [
          (mkScalar "proto" "wireguard")
          (mkScalar "private_key" "@@OWRT_SECRET:WG_VAMRS_PRIVATE_KEY@@")
          (mkList "addresses" [
            "10.0.32.15/32"
            "fd32::15/128"
          ])
          (mkScalar "ip6assign" "64")
          (mkList "dns" [ "192.168.2.1" ])
        ];
      }
      {
        type = "wireguard_vamrs";
        name = null;
        entries = [
          (mkScalar "description" "导入对端配置")
          (mkScalar "public_key" "WVcdwHDpBQq2bg4bJE6zHRdWuPG7mptkuF48HxNFNw4=")
          (mkScalar "persistent_keepalive" "25")
          (mkScalar "endpoint_host" "vamrs.vpndns.net")
          (mkScalar "endpoint_port" "51820")
          (mkScalar "route_allowed_ips" "1")
          (mkList "allowed_ips" [
            "10.0.32.0/24"
            "fd32::/64"
            "192.168.2.0/24"
            "fd02::/64"
            "192.168.31.0/24"
          ])
        ];
      }
      {
        type = "interface";
        name = "chen";
        entries = [
          (mkScalar "proto" "wireguard")
          (mkScalar "private_key" "@@OWRT_SECRET:WG_CHEN_INTERFACE_PRIVATE_KEY@@")
          (mkScalar "listen_port" "51820")
          (mkList "addresses" [ "10.0.33.1/32" ])
        ];
      }
      {
        type = "wireguard_chen";
        name = null;
        entries = [
          (mkScalar "public_key" "2G5YW0LIcguj3TbzSvZZuyU852nCtg8nZqvO8hJD9AE=")
          (mkScalar "private_key" "@@OWRT_SECRET:WG_CHEN_PEER1_PRIVATE_KEY@@")
          (mkList "allowed_ips" [ "10.0.33.2/32" ])
          (mkScalar "route_allowed_ips" "1")
          (mkScalar "persistent_keepalive" "25")
        ];
      }
      {
        type = "wireguard_chen";
        name = null;
        entries = [
          (mkScalar "public_key" "9uAurrT6dpl8IATLWGk65fly+mAFCNsRjPXhxX7GWHo=")
          (mkScalar "private_key" "@@OWRT_SECRET:WG_CHEN_PEER2_PRIVATE_KEY@@")
          (mkScalar "route_allowed_ips" "1")
          (mkScalar "persistent_keepalive" "25")
          (mkList "allowed_ips" [ "10.0.33.3/32" ])
        ];
      }
    ];

    dhcp = renderFile [
      {
        type = "dnsmasq";
        name = null;
        entries = [
          (mkScalar "domainneeded" "1")
          (mkScalar "localise_queries" "1")
          (mkScalar "rebind_protection" "1")
          (mkScalar "rebind_localhost" "1")
          (mkScalar "local" "/lan/")
          (mkScalar "domain" "lan")
          (mkScalar "expandhosts" "1")
          (mkScalar "cachesize" "0")
          (mkScalar "authoritative" "1")
          (mkScalar "readethers" "1")
          (mkScalar "leasefile" "/tmp/dhcp.leases")
          (mkScalar "localservice" "1")
          (mkScalar "ednspacket_max" "1232")
          (mkScalar "localuse" "1")
          (mkList "address" [ "/*.mcdn.bilivideo.cn/" ])
          (mkScalar "noresolv" "0")
          (mkScalar "resolvfile" "/tmp/resolv.conf.d/resolv.conf.auto")
        ];
      }
      {
        type = "dhcp";
        name = "lan";
        entries = [
          (mkScalar "interface" "lan")
          (mkScalar "start" "101")
          (mkScalar "limit" "150")
          (mkScalar "leasetime" "12h")
          (mkScalar "dhcpv4" "server")
          (mkScalar "dhcpv6" "server")
          (mkScalar "ra" "server")
          (mkList "ra_flags" [
            "managed-config"
            "other-config"
          ])
          (mkList "dhcp_option" [ "6,192.168.33.1" ])
        ];
      }
      {
        type = "dhcp";
        name = "wan";
        entries = [
          (mkScalar "interface" "wan")
          (mkScalar "ignore" "1")
        ];
      }
      {
        type = "odhcpd";
        name = "odhcpd";
        entries = [
          (mkScalar "maindhcp" "0")
          (mkScalar "leasefile" "/tmp/hosts/odhcpd")
          (mkScalar "leasetrigger" "/usr/sbin/odhcpd-update")
          (mkScalar "loglevel" "4")
        ];
      }
      {
        type = "host";
        name = null;
        entries = [
          (mkList "mac" [ "6C:24:08:32:40:A1" ])
          (mkScalar "ip" "192.168.33.2")
        ];
      }
      {
        type = "host";
        name = null;
        entries = [
          (mkList "mac" [ "A4:CC:B3:0B:61:29" ])
          (mkScalar "ip" "192.168.33.3")
        ];
      }
      {
        type = "host";
        name = null;
        entries = [
          (mkList "mac" [ "D8:CE:3A:8B:75:C0" ])
          (mkScalar "ip" "192.168.33.4")
        ];
      }
      {
        type = "host";
        name = null;
        entries = [
          (mkList "mac" [ "BC:24:11:35:A9:DE" ])
          (mkScalar "ip" "192.168.33.252")
        ];
      }
      {
        type = "host";
        name = null;
        entries = [
          (mkList "mac" [ "4C:75:25:CF:7C:54" ])
          (mkScalar "ip" "192.168.33.11")
        ];
      }
    ];

    firewall = renderFile [
      {
        type = "defaults";
        name = null;
        entries = [
          (mkScalar "input" "ACCEPT")
          (mkScalar "output" "ACCEPT")
          (mkScalar "forward" "REJECT")
        ];
      }
      {
        type = "zone";
        name = null;
        entries = [
          (mkScalar "name" "lan")
          (mkList "network" [
            "lan"
          ])
          (mkScalar "input" "ACCEPT")
          (mkScalar "output" "ACCEPT")
          (mkScalar "forward" "ACCEPT")
          (mkScalar "masq" "1")
        ];
      }
      {
        type = "zone";
        name = null;
        entries = [
          (mkScalar "name" "wan")
          (mkScalar "input" "ACCEPT")
          (mkScalar "output" "ACCEPT")
          (mkScalar "forward" "ACCEPT")
          (mkScalar "masq" "1")
          (mkScalar "mtu_fix" "1")
          (mkList "network" [
            "wan"
            "wan6"
          ])
        ];
      }
      {
        type = "zone";
        name = null;
        entries = [
          (mkScalar "name" "wg")
          (mkScalar "input" "ACCEPT")
          (mkScalar "output" "ACCEPT")
          (mkScalar "forward" "ACCEPT")
          (mkList "network" [
            "vamrs"
            "chen"
          ])
        ];
      }
      {
        type = "forwarding";
        name = null;
        entries = [
          (mkScalar "src" "lan")
          (mkScalar "dest" "wan")
        ];
      }
      {
        type = "forwarding";
        name = "lan_to_wg";
        entries = [
          (mkScalar "src" "lan")
          (mkScalar "dest" "wg")
        ];
      }
      {
        type = "forwarding";
        name = "wg_to_lan";
        entries = [
          (mkScalar "src" "wg")
          (mkScalar "dest" "lan")
        ];
      }
      {
        type = "rule";
        name = null;
        entries = [
          (mkScalar "name" "Allow-DHCP-Renew")
          (mkScalar "src" "wan")
          (mkScalar "proto" "udp")
          (mkScalar "dest_port" "68")
          (mkScalar "target" "ACCEPT")
          (mkScalar "family" "ipv4")
        ];
      }
      {
        type = "rule";
        name = null;
        entries = [
          (mkScalar "name" "Allow-Ping")
          (mkScalar "src" "wan")
          (mkScalar "proto" "icmp")
          (mkScalar "icmp_type" "echo-request")
          (mkScalar "family" "ipv4")
          (mkScalar "target" "ACCEPT")
        ];
      }
      {
        type = "rule";
        name = null;
        entries = [
          (mkScalar "name" "Allow-IGMP")
          (mkScalar "src" "wan")
          (mkScalar "proto" "igmp")
          (mkScalar "family" "ipv4")
          (mkScalar "target" "ACCEPT")
        ];
      }
      {
        type = "rule";
        name = null;
        entries = [
          (mkScalar "name" "Allow-DHCPv6")
          (mkScalar "src" "wan")
          (mkScalar "proto" "udp")
          (mkScalar "dest_port" "546")
          (mkScalar "family" "ipv6")
          (mkScalar "target" "ACCEPT")
        ];
      }
      {
        type = "rule";
        name = null;
        entries = [
          (mkScalar "name" "Allow-MLD")
          (mkScalar "src" "wan")
          (mkScalar "proto" "icmp")
          (mkScalar "src_ip" "fe80::/10")
          (mkList "icmp_type" [
            "130/0"
            "131/0"
            "132/0"
            "143/0"
          ])
          (mkScalar "family" "ipv6")
          (mkScalar "target" "ACCEPT")
        ];
      }
      {
        type = "rule";
        name = null;
        entries = [
          (mkScalar "name" "Allow-ICMPv6-Input")
          (mkScalar "src" "wan")
          (mkScalar "proto" "icmp")
          (mkList "icmp_type" [
            "echo-request"
            "echo-reply"
            "destination-unreachable"
            "packet-too-big"
            "time-exceeded"
            "bad-header"
            "unknown-header-type"
            "router-solicitation"
            "neighbour-solicitation"
            "router-advertisement"
            "neighbour-advertisement"
          ])
          (mkScalar "limit" "1000/sec")
          (mkScalar "family" "ipv6")
          (mkScalar "target" "ACCEPT")
        ];
      }
      {
        type = "rule";
        name = null;
        entries = [
          (mkScalar "name" "Allow-ICMPv6-Forward")
          (mkScalar "src" "wan")
          (mkScalar "dest" "*")
          (mkScalar "proto" "icmp")
          (mkList "icmp_type" [
            "echo-request"
            "echo-reply"
            "destination-unreachable"
            "packet-too-big"
            "time-exceeded"
            "bad-header"
            "unknown-header-type"
          ])
          (mkScalar "limit" "1000/sec")
          (mkScalar "family" "ipv6")
          (mkScalar "target" "ACCEPT")
        ];
      }
      {
        type = "rule";
        name = null;
        entries = [
          (mkScalar "name" "Allow-IPSec-ESP")
          (mkScalar "src" "wan")
          (mkScalar "dest" "lan")
          (mkScalar "proto" "esp")
          (mkScalar "target" "ACCEPT")
        ];
      }
      {
        type = "rule";
        name = null;
        entries = [
          (mkScalar "name" "Allow-ISAKMP")
          (mkScalar "src" "wan")
          (mkScalar "dest" "lan")
          (mkScalar "dest_port" "500")
          (mkScalar "proto" "udp")
          (mkScalar "target" "ACCEPT")
        ];
      }
      {
        type = "include";
        name = "openclash";
        entries = [
          (mkScalar "type" "script")
          (mkScalar "path" "/var/etc/openclash.include")
        ];
      }
    ];

    dropbear = renderFile [
      {
        type = "dropbear";
        name = null;
        entries = [
          (mkScalar "PasswordAuth" "on")
          (mkScalar "RootPasswordAuth" "on")
          (mkScalar "Port" "22")
        ];
      }
    ];

    rpcd = renderFile [
      {
        type = "rpcd";
        name = null;
        entries = [
          (mkScalar "socket" "/var/run/ubus/ubus.sock")
          (mkScalar "timeout" "30")
        ];
      }
      {
        type = "login";
        name = null;
        entries = [
          (mkScalar "username" "root")
          (mkScalar "password" "@@OWRT_SECRET:RPCD_ROOT_PASSWORD_HASH@@")
          (mkList "read" [ "*" ])
          (mkList "write" [ "*" ])
        ];
      }
    ];

    uhttpd = renderFile [
      {
        type = "uhttpd";
        name = "main";
        entries = [
          (mkList "listen_http" [
            "0.0.0.0:80"
            "[::]:80"
          ])
          (mkList "listen_https" [
            "0.0.0.0:443"
            "[::]:443"
          ])
          (mkScalar "redirect_https" "0")
          (mkScalar "home" "/www")
          (mkScalar "rfc1918_filter" "1")
          (mkScalar "max_requests" "50")
          (mkScalar "max_connections" "100")
          (mkScalar "cert" "/etc/uhttpd.crt")
          (mkScalar "key" "/etc/uhttpd.key")
          (mkScalar "cgi_prefix" "/cgi-bin")
          (mkList "lua_prefix" [ "/cgi-bin/luci=/usr/lib/lua/luci/sgi/uhttpd.lua" ])
          (mkScalar "script_timeout" "3600")
          (mkScalar "network_timeout" "30")
          (mkScalar "http_keepalive" "20")
          (mkScalar "tcp_keepalive" "1")
          (mkScalar "ubus_prefix" "/ubus")
          (mkList "ucode_prefix" [ "/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc" ])
        ];
      }
      {
        type = "cert";
        name = "defaults";
        entries = [
          (mkScalar "days" "730")
          (mkScalar "key_type" "ec")
          (mkScalar "bits" "2048")
          (mkScalar "ec_curve" "P-256")
          (mkScalar "country" "ZZ")
          (mkScalar "state" "Somewhere")
          (mkScalar "location" "Unknown")
          (mkScalar "commonname" "OpenWrt")
        ];
      }
    ];

    ttyd = renderFile [
      {
        type = "ttyd";
        name = null;
        entries = [
          (mkScalar "interface" "@lan")
          (mkScalar "command" "/bin/login")
        ];
      }
    ];

    luci = renderFile [
      {
        type = "core";
        name = "main";
        entries = [
          (mkScalar "lang" "auto")
          (mkScalar "mediaurlbase" "/luci-static/bootstrap")
          (mkScalar "resourcebase" "/luci-static/resources")
          (mkScalar "ubuspath" "/ubus/")
        ];
      }
      {
        type = "extern";
        name = "flash_keep";
        entries = [
          (mkScalar "uci" "/etc/config/")
          (mkScalar "dropbear" "/etc/dropbear/")
          (mkScalar "openvpn" "/etc/openvpn/")
          (mkScalar "passwd" "/etc/passwd")
          (mkScalar "opkg" "/etc/opkg.conf")
          (mkScalar "firewall" "/etc/firewall.user")
          (mkScalar "uploads" "/lib/uci/upload/")
        ];
      }
      {
        type = "internal";
        name = "languages";
        entries = [ (mkScalar "zh_cn" "简体中文 (Chinese Simplified)") ];
      }
      {
        type = "internal";
        name = "sauth";
        entries = [
          (mkScalar "sessionpath" "/tmp/luci-sessions")
          (mkScalar "sessiontime" "3600")
        ];
      }
      {
        type = "internal";
        name = "ccache";
        entries = [ (mkScalar "enable" "1") ];
      }
      {
        type = "internal";
        name = "themes";
        entries = [
          (mkScalar "Bootstrap" "/luci-static/bootstrap")
          (mkScalar "BootstrapDark" "/luci-static/bootstrap-dark")
          (mkScalar "BootstrapLight" "/luci-static/bootstrap-light")
        ];
      }
      {
        type = "internal";
        name = "apply";
        entries = [
          (mkScalar "rollback" "90")
          (mkScalar "holdoff" "4")
          (mkScalar "timeout" "5")
          (mkScalar "display" "1.5")
        ];
      }
      {
        type = "internal";
        name = "diag";
        entries = [
          (mkScalar "dns" "openwrt.org")
          (mkScalar "ping" "openwrt.org")
          (mkScalar "route" "openwrt.org")
        ];
      }
    ];

    upnpd = renderFile [
      {
        type = "upnpd";
        name = "config";
        entries = [
          (mkScalar "enabled" "0")
          (mkScalar "download" "1024")
          (mkScalar "upload" "512")
          (mkScalar "internal_iface" "lan")
          (mkScalar "port" "5000")
          (mkScalar "upnp_lease_file" "/var/run/miniupnpd.leases")
          (mkScalar "igdv1" "1")
          (mkScalar "uuid" "40672715-062f-40ef-be16-dd4327bd4fc2")
          (mkScalar "enable_upnp" "0")
        ];
      }
      {
        type = "perm_rule";
        name = null;
        entries = [
          (mkScalar "action" "allow")
          (mkScalar "ext_ports" "1024-65535")
          (mkScalar "int_addr" "0.0.0.0/0")
          (mkScalar "int_ports" "1024-65535")
          (mkScalar "comment" "Allow high ports")
        ];
      }
      {
        type = "perm_rule";
        name = null;
        entries = [
          (mkScalar "action" "deny")
          (mkScalar "ext_ports" "0-65535")
          (mkScalar "int_addr" "0.0.0.0/0")
          (mkScalar "int_ports" "0-65535")
          (mkScalar "comment" "Default deny")
        ];
      }
    ];

    natfrp = renderFile [
      {
        type = "natfrp";
        name = "main";
        entries = [
          (mkScalar "remote_mgmt" "1")
          (mkScalar "webui" "1")
          (mkScalar "webui_port" "4101")
          (mkScalar "webui_host" "0.0.0.0")
          (mkScalar "check_update" "1")
          (mkScalar "enabled" "1")
        ];
      }
    ];
  };
in
{
  inherit files;
  fileNames = builtins.attrNames files;
  requiredSecrets = [
    "WAN_PPPOE_USERNAME"
    "WAN_PPPOE_PASSWORD"
    "WG_VAMRS_PRIVATE_KEY"
    "WG_CHEN_INTERFACE_PRIVATE_KEY"
    "WG_CHEN_PEER1_PRIVATE_KEY"
    "WG_CHEN_PEER2_PRIVATE_KEY"
    "RPCD_ROOT_PASSWORD_HASH"
    "OPENCLASH_DASHBOARD_PASSWORD"
    "OPENCLASH_SUBSCRIBE_ADDRESS"
    "OPENCLASH_SUBSCRIBE_INFO_URL"
  ];
}
