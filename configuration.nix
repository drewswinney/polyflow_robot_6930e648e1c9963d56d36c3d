{ config, pkgs, lib, webrtcPkg, pyEnv, webrtcEnv, robotConsoleStatic, robotApiPkg, rosWorkspace, rosWorkspaceEnv, ... }:

let
  user      = "admin";
  password  = "password";
  hostname  = "6930e648e1c9963d56d36c3d";
  homeDir   = "/home/${user}";
  githubUser = "drewswinney";

  py  = pkgs.python3;   # pinned to 3.12 by flake overlay

  rosPkgs = pkgs.rosPackages.humble;
  ros2pkg = rosPkgs.ros2pkg;
  ros2cli = rosPkgs.ros2cli;
  ros2launch = rosPkgs.ros2launch;
  launch = rosPkgs.launch;
  launch-ros = rosPkgs.launch-ros;
  rclpy = rosPkgs.rclpy;
  ament-index-python = rosPkgs.ament-index-python;
  rosidl-parser = rosPkgs.rosidl-parser;
  rosidl-runtime-py = rosPkgs.rosidl-runtime-py;
  composition-interfaces = rosPkgs.composition-interfaces;
  osrf-pycommon = rosPkgs.osrf-pycommon;
  rpyutils = rosPkgs.rpyutils;
  rcl-interfaces = rosPkgs.rcl-interfaces;
  builtin-interfaces = rosPkgs.builtin-interfaces;
  rmwImplementation = rosPkgs."rmw-implementation";
  rmwCycloneDDS = rosPkgs."rmw-cyclonedds-cpp";
  rmwDdsCommon = rosPkgs."rmw-dds-common";
  rosidlTypesupportCpp = rosPkgs."rosidl-typesupport-cpp";
  rosidlTypesupportC = rosPkgs."rosidl-typesupport-c";
  rosidlTypesupportIntrospectionCpp = rosPkgs."rosidl-typesupport-introspection-cpp";
  rosidlTypesupportIntrospectionC = rosPkgs."rosidl-typesupport-introspection-c";
  rosidlGeneratorPy = rosPkgs."rosidl-generator-py";
  yaml = pkgs.python3Packages."pyyaml";
  empy = pkgs.python3Packages."empy";
  catkin-pkg = pkgs.python3Packages."catkin-pkg";
  rosgraphMsgs = rosPkgs."rosgraph-msgs";
  stdMsgs = rosPkgs."std-msgs";

  rosRuntimePackages = [
    ros2pkg
    ros2cli
    ros2launch
    launch
    launch-ros
    rclpy
    ament-index-python
    rosidl-parser
    rosidl-runtime-py
    composition-interfaces
    osrf-pycommon
    rpyutils
    builtin-interfaces
    rcl-interfaces
    rmwImplementation
    rmwCycloneDDS
    rmwDdsCommon
    rosidlTypesupportCpp
    rosidlTypesupportC
    rosidlTypesupportIntrospectionCpp
    rosidlTypesupportIntrospectionC
    rosidlGeneratorPy
    rosgraphMsgs
    stdMsgs
    yaml
  ];

  pythonRoots = rosRuntimePackages ++ [ pyEnv webrtcEnv webrtcPkg ];
  pythonPath = lib.makeSearchPath "lib/python${py.pythonVersion}/site-packages" pythonRoots;

  amentRoots = rosRuntimePackages ++ [ webrtcPkg ];
  amentPrefixPath = lib.concatStringsSep ":" (map (pkg: "${pkg}") amentRoots);

  webrtcRuntimeInputs = rosRuntimePackages ++ [ pyEnv webrtcEnv webrtcPkg ];
  runtimePrefixes = lib.concatStringsSep " " (map (pkg: "${pkg}") webrtcRuntimeInputs);
  libraryPath = lib.makeLibraryPath webrtcRuntimeInputs;

  workspaceLauncher = pkgs.writeShellApplication {
    name = "polyflow-workspace-launch";
    runtimeInputs = [
      rosWorkspaceEnv
      rosWorkspace
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail

      PATH="''${PATH-}"
      PYTHONPATH="''${PYTHONPATH-}"
      AMENT_PREFIX_PATH="''${AMENT_PREFIX_PATH-}"
      LD_LIBRARY_PATH="''${LD_LIBRARY_PATH-}"

      setup_scripts=(
        # High-level env from rosWorkspaceEnv
        "${rosWorkspaceEnv}/setup.bash"
        "${rosWorkspaceEnv}/local_setup.bash"

        # Direct workspace env
        "${rosWorkspace}/setup.bash"
        "${rosWorkspace}/local_setup.bash"
      )

      # Also pick up per-package local_setup scripts from both env + workspace
      for prefix in "${rosWorkspaceEnv}" "${rosWorkspace}"; do
        for script in "$prefix"/share/*/local_setup.bash "$prefix"/share/*/setup.bash; do
          if [ -f "$script" ]; then
            setup_scripts+=("$script")
          fi
        done
      done

      set +u
      for script in "''${setup_scripts[@]}"; do
        [ -f "$script" ] || continue
        echo "[workspace-launch] Sourcing $script" >&2
        # shellcheck disable=SC1090
        . "$script"
      done
      set -u

      launch_entries=()
      while IFS= read -r launch_file; do
        pkg=$(basename "$(dirname "$launch_file")")
        base=$(basename "$launch_file")
        launch_entries+=("$pkg:$base")
      done < <(find "${rosWorkspace}/share" -maxdepth 3 -type f -name '*.launch.py' -print | sort)

      if [ "''${#launch_entries[@]}" -eq 0 ]; then
        echo "[workspace-launch] No launch files found under ${rosWorkspace}/share" >&2
        exit 0
      fi

      declare -a pids
      cleanup() {
        for pid in "''${pids[@]}"; do
          if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
          fi
        done
        wait
      }
      trap cleanup EXIT

      for entry in "''${launch_entries[@]}"; do
        pkg="''${entry%%:*}"
        launch="''${entry#*:}"
        echo "[workspace-launch] Starting: ros2 launch $pkg $launch" >&2
        ros2 launch "$pkg" "$launch" &
        pids+=("$!")
      done

      wait
    '';
  };

  webrtcLauncher = pkgs.writeShellApplication {
    name = "webrtc-launch";
    runtimeInputs = webrtcRuntimeInputs;
    text = ''
      set -eo pipefail

      # Guard PATH/PYTHONPATH before enabling nounset; systemd often runs with them unset.
      PATH="''${PATH-}"
      PYTHONPATH="''${PYTHONPATH-}"
      AMENT_PREFIX_PATH="''${AMENT_PREFIX_PATH-}"
      LD_LIBRARY_PATH="''${LD_LIBRARY_PATH-}"
      if [ -z "''${RMW_IMPLEMENTATION-}" ]; then
        RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
      fi
      export RMW_IMPLEMENTATION

      set -u
      shopt -s nullglob

      PYTHONPATH_BASE="${pythonPath}"
      if [ -n "$PYTHONPATH_BASE" ]; then
        PYTHONPATH="$PYTHONPATH_BASE''${PYTHONPATH:+:}''${PYTHONPATH}"
      fi

      AMENT_PREFIX_BASE="${amentPrefixPath}"
      if [ -n "$AMENT_PREFIX_BASE" ]; then
        AMENT_PREFIX_PATH="$AMENT_PREFIX_BASE''${AMENT_PREFIX_PATH:+:}''${AMENT_PREFIX_PATH}"
      fi

      LIBRARY_PATH_BASE="${libraryPath}"
      if [ -n "$LIBRARY_PATH_BASE" ]; then
        LD_LIBRARY_PATH="$LIBRARY_PATH_BASE''${LD_LIBRARY_PATH:+:}''${LD_LIBRARY_PATH}"
      fi

      export PYTHONPATH
      export AMENT_PREFIX_PATH
      export LD_LIBRARY_PATH

      # Local setup scripts expect AMENT_TRACE_SETUP_FILES to be unset when absent.
      set +u
      for prefix in ${runtimePrefixes}; do
        for script in "$prefix"/setup.bash "$prefix"/local_setup.bash \
                      "$prefix"/install/setup.bash "$prefix"/install/local_setup.bash \
                      "$prefix"/share/*/local_setup.bash "$prefix"/share/*/setup.bash; do
          if [ -f "$script" ]; then
            echo "[INFO] Sourcing $script" >&2
            # shellcheck disable=SC1090
            . "$script"
          fi
        done
      done
      set -u

      exec ros2 launch webrtc webrtc.launch.py
    '';
  };

  wifiConfPath = "/var/lib/polyflow/wifi.conf";
  rosServicesToRestart = [
    "polyflow-webrtc.service"
  ];

  nixosRebuildRunner = pkgs.writeShellApplication {
    name = "polyflow-nixos-rebuild";
    runtimeInputs = [ pkgs.nixos-rebuild pkgs.git pkgs.nix ];
    text = ''
      set -euo pipefail

      REPO_USER="${githubUser}"
      if [ -z "$REPO_USER" ]; then
        echo "[nixos-rebuild] GitHub user not configured" >&2
        exit 1
      fi

      if printf '%s' "$REPO_USER" | grep -qE '[[:space:]]'; then
        echo "[nixos-rebuild] Rejecting GitHub user with whitespace" >&2
        exit 1
      fi

      ROBOT_ID_ENV="${hostname}"
      if [ -z "$ROBOT_ID_ENV" ]; then
        ROBOT_ID_ENV="$(hostname)"
      fi

      if printf '%s' "$ROBOT_ID_ENV" | grep -qE '[[:space:]]'; then
        echo "[nixos-rebuild] Rejecting robot id with whitespace" >&2
        exit 1
      fi

      FLAKE_REF="github:''${REPO_USER}/polyflow_robot_''${ROBOT_ID_ENV}#rpi4"

      exec sudo nixos-rebuild switch --flake "$FLAKE_REF" --accept-flake-config
    '';
  };

  # SocketCAN (Waveshare 2-CH CAN FD HAT, MCP2517/8FD) defaults; adjust to match wiring.
  canOscillatorHz = 40000000;
  can0InterruptGpio = 25;
  can1InterruptGpio = 24;
  canSpiMaxFrequency = 8000000;
  canBaseBitRate = 500000;
  canFdDataBitRate = 2000000;

  # Switch between hotspot (AP) and client (STA) depending on presence of saved Wi-Fi credentials.
  # Credentials file: /var/lib/polyflow/wifi.conf with lines:
  #   WIFI_SSID="MyNetwork"
  #   WIFI_PSK="supersecret"
  wifiModeSwitch = pkgs.writeShellApplication {
    name = "polyflow-wifi-mode";
    runtimeInputs = [ pkgs.networkmanager pkgs.gawk pkgs.coreutils pkgs.systemd ];
    text = ''
      set -euo pipefail

      HOSTNAME="${hostname}"
      WIFI_CONF="${wifiConfPath}"
      ROS_SERVICES=(
        ${lib.concatMapStrings (svc: ''"${svc}"
        '') rosServicesToRestart}
      )

      restart_ros_services() {
        if [ "''${#ROS_SERVICES[@]}" -eq 0 ]; then
          return
        fi
        local svc
        for svc in "''${ROS_SERVICES[@]}"; do
          if [ -z "$svc" ]; then
            continue
          fi
          echo "[wifi-mode] Restarting $svc after STA activation" >&2
          if ! systemctl restart "$svc"; then
            echo "[wifi-mode] Warning: failed to restart $svc" >&2
          fi
        done
      }

     
      # wait up to ~10s for NM + wifi device
      for _ in $(seq 1 20); do
        if nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep -q ":wifi"; then
          break
        fi
        sleep 0.5
      done

      WIFI_IF="$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="wifi"{print $1;exit}')"
      if [ -z "$WIFI_IF" ]; then
        echo "[wifi-mode] No Wi-Fi interface found" >&2
        exit 0
      fi

      ensure_ap() {
        local ap_ssid="polyflow-robot-setup"
        local ap_pass="${password}"

        if ! nmcli -t -f NAME connection show | grep -Fx "robot-ap" >/dev/null; then
          # Add AP profile with shared-mode up front to avoid race on first activation
          nmcli connection add type wifi ifname "$WIFI_IF" mode ap con-name robot-ap ssid "$ap_ssid" \
            ipv4.method shared ipv6.method ignore

          nmcli connection modify robot-ap \
            802-11-wireless.band bg \
            802-11-wireless.channel 1 \
            802-11-wireless-security.key-mgmt wpa-psk \
            802-11-wireless-security.psk "$ap_pass"
        fi

        nmcli connection modify robot-ap connection.autoconnect yes || true

        # Remove any stale dnsmasq pid that can block shared-mode start (iface-safe)
        rm -f "/run/nm-dnsmasq-''${WIFI_IF}.pid" 2>/dev/null || true

        # Force a clean up/down to dodge first-boot AP races
        nmcli connection down robot-ap || true
        nmcli connection up robot-ap || true
      }

      # If no credentials, start AP
      if [ ! -f "$WIFI_CONF" ]; then
        echo "[wifi-mode] wifi.conf missing; enabling AP mode" >&2
        ensure_ap
        exit 0
      fi

      # Read credentials
      WIFI_SSID=""
      WIFI_PSK=""
      # shellcheck disable=SC1090
      source "$WIFI_CONF" || true
      if [ -z "''${WIFI_SSID:-}" ]; then
        echo "[wifi-mode] WIFI_SSID empty; enabling AP mode" >&2
        ensure_ap
        exit 0
      fi

      # Find the first robot-wifi UUID (if any)
      ROBOT_UUID="$(nmcli -t -f UUID,NAME connection show \
        | awk -F: '$2=="robot-wifi"{print $1; exit}')"

      if [ -z "$ROBOT_UUID" ]; then
        nmcli connection add type wifi ifname "$WIFI_IF" con-name robot-wifi ssid "$WIFI_SSID"
        # Capture UUID for the newly created connection so we never rely on NAME
        ROBOT_UUID="$(nmcli -t -f UUID,NAME connection show \
          | awk -F: '$2=="robot-wifi"{print $1; exit}')"
      else
        nmcli connection modify "$ROBOT_UUID" 802-11-wireless.ssid "$WIFI_SSID"
      fi

      if [ -n "''${WIFI_PSK:-}" ]; then
        nmcli connection modify "$ROBOT_UUID" \
          802-11-wireless-security.key-mgmt wpa-psk \
          802-11-wireless-security.psk "$WIFI_PSK" \
          802-11-wireless-security.psk-flags 0
      else
        nmcli connection modify "$ROBOT_UUID" 802-11-wireless-security.key-mgmt none
        # (Per your request, not applying my earlier “clear stale PSK” suggestion.)
      fi

      nmcli connection modify "$ROBOT_UUID" \
        ipv4.method auto \
        ipv6.method auto \
        connection.autoconnect yes \
        connection.permissions ""

      # Optional stability tweak (NOT forcing, just leaving note):
      # If STA bring-up is slow/flaky on some networks, consider:
      # nmcli connection modify "$ROBOT_UUID" ipv6.method disabled

      # Keep AP disabled whenever creds are present to avoid concurrent AP+STA.
      nmcli connection modify robot-ap connection.autoconnect no || true

      echo "[wifi-mode] Bringing up STA connection to SSID=$WIFI_SSID" >&2
      rm -f "/run/nm-dnsmasq-''${WIFI_IF}.pid" 2>/dev/null || true
      nmcli connection down robot-ap || true

      # Re-apply PSK every run to ensure NM has the secret stored.
      if [ -n "''${WIFI_PSK:-}" ]; then
        nmcli connection modify "$ROBOT_UUID" \
          802-11-wireless-security.key-mgmt wpa-psk \
          802-11-wireless-security.psk "$WIFI_PSK"
      fi

      if nmcli connection up "$ROBOT_UUID"; then
        echo "[wifi-mode] STA connected; AP will remain off while creds exist" >&2
        restart_ros_services
      else
        echo "[wifi-mode] STA connection failed; re-enabling AP for setup" >&2
        nmcli connection modify robot-ap connection.autoconnect yes || true
        ensure_ap
        exit 0
      fi
    '';
  };
in
{
  ##############################################################################
  # Hardware / boot
  ##############################################################################
  nixpkgs.overlays = [
    (final: super: {
      makeModulesClosure = x:
        super.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  boot = {
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];

    loader = {
      grub.enable = false;
      generic-extlinux-compatible = {
        enable = true;
        useGenerationDeviceTree = true;
      };
    };

    # Quiet kernel output on console (keep in journal)
    consoleLogLevel = 3; # errors only
    kernel.sysctl."kernel.printk" = "3 4 1 3";
    kernelModules = [
      "can"
      "can_raw"
      "mcp251xfd"
      "spi_bcm2835"
    ];

    kernelPackages = pkgs.linuxKernel.packages.linux_6_1;
    supportedFilesystems = lib.mkForce [ "vfat" "ext4" ];
  };

  hardware = {
    enableRedistributableFirmware = true;

    # Tie into the Pi-4 dtmerge pipeline from nixos-hardware
    raspberry-pi."4".apply-overlays-dtmerge.enable = true;

    deviceTree = {
      enable = true;

      # Be explicit about the base DTB; this matches what the Pi-4 hw module uses.
      # (This avoids “overlays merged into the wrong DTB” issues.)
      filter = "bcm2711-rpi-4-b.dtb";

      overlays = [
        {
          name = "polyflow-waveshare-can-fd-hat-mode-a";
          dtsFile = ./overlays/polyflow-waveshare-can-fd-hat-mode-a.dts;
        }
      ];
    };
  };

  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  ##############################################################################
  # System basics
  ##############################################################################
  system.autoUpgrade.flags = [ "--max-jobs" "1" "--cores" "1" ];
  systemd.services.NetworkManager-wait-online.enable = false;

  systemd.network = {
    enable = true;
    wait-online.enable = false;

    netdevs."10-dummy0" = {
      netdevConfig = {
        Name = "dummy0";
        Kind = "dummy";
      };
    };

    networks."10-dummy0" = {
      matchConfig.Name = "dummy0";
      address = [ "10.254.254.1/32" ];
      networkConfig.ConfigureWithoutCarrier = true;
      linkConfig.RequiredForOnline = false;
    };
  };

  networking = {
    hostName = hostname;
    networkmanager.enable = true;
    networkmanager.wifi.powersave = false;
    networkmanager.logLevel = "WARN";
    useDHCP = false;
    dhcpcd.enable = false;
    nftables.enable = true;
    firewall = {
      allowedTCPPorts = [ 80 ];
      # Allow DHCP/DNS on the hotspot interface so clients can get leases.
      interfaces."wlan0" = {
        allowedUDPPorts = [ 53 67 68 ];
        allowedTCPPorts = [ 53 ];
      };
    };
  };

  services.openssh.enable = true;
  services.avahi = {
    enable = true;
    publish.enable = true;
    publish.addresses = true;
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/polyflow 0755 root root -"
    "d /var/lib/grafana-loki 0750 loki loki - -"
    # Clean any stale dnsmasq PID file NetworkManager might leave
    "r /run/nm-dnsmasq-wlan0.pid"
  ];
  services.caddy.enable = false;

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = false;
    virtualHosts."default" = {
      listen = [
        {
          addr = "0.0.0.0";
          port = 80;
        }
      ];
      locations = {
        # Strip the /api/ prefix when proxying to the FastAPI app
        "/api/" = {
           proxyPass = "http://127.0.0.1:8082/";
           proxyWebsockets = true;
        };
        "/" = {
          root = "${robotConsoleStatic}/dist";
          tryFiles = "$uri $uri/ /index.html";
          extraConfig = "autoindex off;";
        };
      };
    };
  };
  
  # Build-time NSS in the sandbox lacks a root entry; skip logrotate config check
  # to avoid failing builds in nixos-generate/docker.
  services.logrotate.checkConfig = false;
  services.timesyncd.enable = lib.mkDefault true;
  services.timesyncd.servers = [ "pool.ntp.org" ];
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "multi-user.target" ];

  # Local Prometheus Node Exporter (scraped by Alloy)
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9100;
    enabledCollectors = [ "systemd" "processes" "tcpstat" ];
  };

  # No extra NSS modules; disable nscd to avoid PID file permission warnings.
  system.nssModules = lib.mkForce [];
  services.nscd.enable = false;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" user ];
    trusted-substituters = [ "https://ros.cachix.org" ];
    trusted-public-keys = [
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
    ];
    accept-flake-config = true;
  };

  system.stateVersion = "23.11";

  environment.etc."alloy/config.alloy" = {
    source = ./config.alloy;
    mode = "0644";
  };

  ##############################################################################
  # Users
  ##############################################################################
  users.mutableUsers = false;
  # Keep an explicit root entry so builds that query user 0 (e.g., logrotate.conf)
  # can resolve it even with immutable users. Set uid/gid explicitly and lock the
  # password so root password auth stays disabled.
  users.groups.root.gid = 0;
  users.users.root = {
    uid = 0;
    group = "root";
    isSystemUser = true;
    hashedPassword = "!";
  };
  users.users.${user} = {
    isNormalUser = true;
    password = password;
    extraGroups = [ "wheel" ];
    home = homeDir;
  };
  security.sudo.wheelNeedsPassword = false;

  ##############################################################################
  # Packages
  ##############################################################################
  environment.systemPackages =
    (with pkgs; [ git python3 can-utils iproute2 ]) ++
    (with rosPkgs; [ ros2cli ros2launch ros2pkg launch launch-ros ament-index-python ros-base ]) ++
    [ webrtcPkg pyEnv ];

  ##############################################################################
  # Services
  ##############################################################################
  # Boot-time Wi-Fi mode selection: hotspot when no creds, STA when configured.
  systemd.services.polyflow-wifi-mode = {
    description = "Polyflow Wi-Fi mode switch (AP vs STA)";
    wantedBy = [ "multi-user.target" ];
    after = [ "NetworkManager.service" ];
    wants = [ "NetworkManager.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${wifiModeSwitch}/bin/polyflow-wifi-mode";
      RemainAfterExit = true;
      Restart = "no"; # be explicit
    };
  };

  systemd.paths.polyflow-wifi-mode = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = wifiConfPath;
      PathExists = wifiConfPath;
      Unit = "polyflow-wifi-mode.service";
    };
  };

  systemd.services.polyflow-robot-api = {
    description = "Polyflow Robot REST API";
    wantedBy = [ "multi-user.target" ];
    after  = [ "NetworkManager.service" ];
    wants  = [ "NetworkManager.service" ];
    environment = {
      WIFI_CONF_PATH = wifiConfPath;
      WIFI_SWITCH_CMD = "${wifiModeSwitch}/bin/polyflow-wifi-mode";
      ROBOT_API_TOKEN_PATH = "/var/lib/polyflow/api_token";
      ROBOT_API_ALLOWED_ORIGINS = "http://localhost,http://127.0.0.1,http://localhost:5173,http://127.0.0.1:5173,http://localhost:4173,http://127.0.0.1:4173,http://${hostname}.local";
      ALLOY_LOKI_TAIL_URL = "ws://127.0.0.1:3100/loki/api/v1/tail";
    };
    serviceConfig = {
      ExecStart = "${robotApiPkg}/bin/robot-api";
      WorkingDirectory = "/var/lib/polyflow";
      Restart = "on-failure";
      RestartSec = "2s";
    };
  };

  systemd.services.grafana-alloy = {
    description = "Grafana Alloy metrics collector";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    wants = [ ];
    serviceConfig = {
      ExecStart = "${pkgs.grafana-alloy}/bin/alloy run --storage.path /var/lib/grafana-alloy /etc/alloy/config.alloy";
      Restart = "on-failure";
      RestartSec = "5s";
      DynamicUser = true;
      Environment = "ROBOT_ID=${hostname}";
      StateDirectory = "grafana-alloy";
      WorkingDirectory = "/var/lib/grafana-alloy";
      SupplementaryGroups = lib.mkAfter [ "systemd-journal" ];
    };
  };

  services.loki = {
    enable = true;
    dataDir = "/var/lib/grafana-loki";
    configuration = {
      server = {
        http_listen_address = "127.0.0.1";
        http_listen_port = 3100;
        grpc_listen_address = "0.0.0.0";
        grpc_listen_port = 9095;
      };

      auth_enabled = false;

      common = {
        path_prefix = "/var/lib/grafana-loki";
        replication_factor = 1;
        instance_interface_names = [ "dummy0" ];
        ring = {
          kvstore.store = "inmemory";
          instance_addr = "10.254.254.1";
        };
      };

      ingester = {
        wal.enabled = false;
        lifecycler = {
          address = "10.254.254.1";
          join_after = "0s";
          final_sleep = "0s";
        };
      };

      memberlist = {
        bind_addr = [ "10.254.254.1" ];
        advertise_addr = "10.254.254.1";
        bind_port = 7946;
        advertise_port = 7946;
        join_members = [ ];
        abort_if_cluster_join_fails = false;
      };

      ingester_client.remote_timeout = "10s";

      schema_config.configs = [{
        from = "2024-01-01";
        store = "tsdb";
        object_store = "filesystem";
        schema = "v13";
        index = {
          prefix = "loki_index_";
          period = "24h";
        };
      }];

      storage_config = {
        tsdb_shipper = {
          active_index_directory = "/var/lib/grafana-loki/tsdb-index";
          cache_location = "/var/lib/grafana-loki/tsdb-cache";
        };
        filesystem.directory = "/var/lib/grafana-loki/chunks";
      };

      compactor = {
        working_directory = "/var/lib/grafana-loki/compactor";
        retention_enabled = true;
        retention_delete_delay = "2h";
        delete_request_store = "filesystem";
        compaction_interval = "10m";
      };

      ruler = {
        rule_path = "/var/lib/grafana-loki/rules";
        ring.kvstore.store = "inmemory";
        wal.dir = "/var/lib/grafana-loki/ruler-wal";
      };

      query_range.results_cache.cache.embedded_cache = {
        enabled = true;
        max_size_mb = 32;
      };

      limits_config = {
        ingestion_rate_mb = 8;
        ingestion_burst_size_mb = 16;
        allow_structured_metadata = false;

        retention_period = "168h";
      };

      analytics.reporting_enabled = false;
    };
  };


  systemd.services.loki = {
    after = lib.mkAfter [
      "network.target"
      "polyflow-wifi-mode.service"
    ];

    wants = [ ];

    serviceConfig = {
      Restart = "always";
      RestartSec = 2;
    };
  };

  systemd.services.polyflow-webrtc = {
    description = "Run Polyflow WebRTC launch with ros2 launch";
    after    = [ "network-online.target" "polyflow-wifi-mode.service" ];
    wants    = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    
    environment = {
      ROS_DOMAIN_ID = "0";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    restartIfChanged = true;
    restartTriggers = [ webrtcPkg webrtcEnv webrtcLauncher ];

    serviceConfig = {
      User             = user;
      Group            = "users";
      WorkingDirectory = homeDir;
      StateDirectory   = "polyflow";
      StandardOutput   = "journal";
      StandardError    = "journal";
      Restart          = "always";
      RestartSec       = "3s";
      ExecStart        = "${webrtcLauncher}/bin/webrtc-launch";
    };
  };

  systemd.services.polyflow-ros-workspace = {
    description = "Run all ROS workspace launch files";
    after    = [ "network-online.target" "polyflow-wifi-mode.service" ];
    wants    = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      ROS_DOMAIN_ID = "0";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    serviceConfig = {
      User             = user;
      Group            = "users";
      WorkingDirectory = homeDir;
      StateDirectory   = "polyflow";
      StandardOutput   = "journal";
      StandardError    = "journal";
      Restart = "on-failure";
      RestartSec = "2s";
      ExecStart        = "${workspaceLauncher}/bin/polyflow-workspace-launch";
    };
  };

  systemd.services.polyflow-nixos-rebuild = {
    description = "Rebuild NixOS from GitHub flake (triggered remotely)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.git pkgs.nix pkgs.nixos-rebuild ];
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/var/lib/polyflow";
      StandardOutput = "journal";
      StandardError = "journal";
      ExecStart = "${nixosRebuildRunner}/bin/polyflow-nixos-rebuild";
    };
  };

  # CAN0 (spi0.0 -> can0)
  systemd.services.can0-up = {
    description = "Bring up CAN0 (MCP2518FD on spi0.0)";
    wantedBy    = [ "multi-user.target" ];

    # Wait until the net device exists
    after    = [ "sys-subsystem-net-devices-can0.device" ];
    requires = [ "sys-subsystem-net-devices-can0.device" ];

    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        # Make sure it's down first
        "${pkgs.iproute2}/bin/ip link set can0 down"
        # Configure CAN-FD: 1 Mbps arb, 2 Mbps data
        "${pkgs.iproute2}/bin/ip link set can0 type can bitrate 1000000 dbitrate 2000000 fd on"
        # Bring it up
        "${pkgs.iproute2}/bin/ip link set can0 up"
      ];
      ExecStop = "${pkgs.iproute2}/bin/ip link set can0 down";
    };
  };

  # CAN1 (spi1.0 -> can1)
  systemd.services.can1-up = {
    description = "Bring up CAN1 (MCP2518FD on spi1.0)";
    wantedBy    = [ "multi-user.target" ];

    after    = [ "sys-subsystem-net-devices-can1.device" ];
    requires = [ "sys-subsystem-net-devices-can1.device" ];

    serviceConfig = {
      Type           = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "${pkgs.iproute2}/bin/ip link set can1 down"
        "${pkgs.iproute2}/bin/ip link set can1 type can bitrate 1000000 dbitrate 2000000 fd on"
        "${pkgs.iproute2}/bin/ip link set can1 up"
      ];
      ExecStop = "${pkgs.iproute2}/bin/ip link set can1 down";
    };
  };
}
