{
  description = "NixOS (Pi 4) + ROS 2 Humble + prebuilt colcon workspace";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://ros.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
    ];
  };

  ##############################################################################
  # Inputs
  ##############################################################################
  inputs = {
    nix-ros-overlay.url = "github:lopsided98/nix-ros-overlay";
    nix-ros-overlay.flake = false;
    nixpkgs.url = "github:lopsided98/nixpkgs/nix-ros";
    poetry2nix.url = "github:nix-community/poetry2nix";
    poetry2nix.inputs.nixpkgs.follows = "nixpkgs";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nix-ros-workspace.url = "github:hacker1024/nix-ros-workspace";
    nix-ros-workspace.flake = false;
  };

  ##############################################################################
  # Outputs
  ##############################################################################
  outputs = { self, nixpkgs, poetry2nix, nixos-hardware, nix-ros-workspace, nix-ros-overlay, ... }:
  let
    system = "aarch64-linux";

    # Overlay: pin python3 -> python312 (ROS Humble Python deps are happy here)
    pinPython312 = final: prev: {
      python3         = prev.python312;
      python3Packages = prev.python312Packages;
    };

        # ROS overlay setup from nix-ros-overlay (non-flake)
    rosBase = import nix-ros-overlay { inherit system; };

    rosOverlays =
      if builtins.isFunction rosBase then
        # Direct overlay function
        [ rosBase ]
      else if builtins.isList rosBase then
        # Already a list of overlay functions
        rosBase
      else if rosBase ? default && builtins.isFunction rosBase.default then
        # Attrset with a `default` overlay
        [ rosBase.default ]
      else if rosBase ? overlays && builtins.isList rosBase.overlays then
        # Attrset with `overlays = [ overlay1 overlay2 … ]`
        rosBase.overlays
      else if rosBase ? overlays
           && rosBase.overlays ? default
           && builtins.isFunction rosBase.overlays.default then
        # Attrset with `overlays.default` as the primary overlay
        [ rosBase.overlays.default ]
      else
        throw "nix-ros-overlay: unexpected structure; expected an overlay or list of overlays";

    rosWorkspaceOverlay = (import nix-ros-workspace { inherit system; }).overlay;
    
    pkgs = import nixpkgs {
      inherit system;
      overlays = rosOverlays ++ [ rosWorkspaceOverlay pinPython312 ];
    };

    poetry2nixPkgs = poetry2nix.lib.mkPoetry2Nix { inherit pkgs; };

    lib     = pkgs.lib;
    rosPkgs = pkgs.rosPackages.humble;

    ############################################################################
    # Workspace discovery
    ############################################################################

    # Prefer a workspace folder within the repo; fall back to common sibling paths.
    workspaceCandidates = [
      ./workspace
      ../workspace
      ../../shared/workspace
    ];
    workspaceRoot =
      let existing = builtins.filter builtins.pathExists workspaceCandidates;
      in if existing != [ ] then builtins.head existing else
        throw "workspace directory not found; expected one of: "
          + (builtins.concatStringsSep ", " (map (p: builtins.toString p) workspaceCandidates));
    workspaceSrcPath =
      let path = "${workspaceRoot}/src";
      in if builtins.pathExists path then path else
        throw "workspace src not found at ${path}";

    webrtcSrc = pkgs.lib.cleanSourceWith {
      src = builtins.path { path = builtins.toString (./workspace) + "/src/webrtc"; name = "webrtc-src"; };
      filter = path: type:
        # include typical project files; drop bytecode and VCS junk
        !(pkgs.lib.hasSuffix ".pyc" path)
        && !(pkgs.lib.hasInfix "/__pycache__/" path)
        && !(pkgs.lib.hasInfix "/.git/" path);
    };

    webrtcEnv = poetry2nixPkgs.mkPoetryEnv {
      projectDir = webrtcSrc;
      preferWheels = true;
      python = py;
    };

    # Robot Console static assets (expects dist/ already built in ./robot-console)
    robotConsoleSrc = builtins.path { path = ./robot-console; name = "robot-console"; };

    robotConsoleStatic = pkgs.stdenv.mkDerivation {
      pname = "polyflow-robot-console-static";
      version = "0.1.0";

      src = robotConsoleSrc;

      buildPhase = ''
        mkdir -p $out
        cp -R dist/* $out/
      '';

      installPhase = "true";
    };

    # Robot API (nest.js) from ./robot-api
    robotApiSrc = pkgs.lib.cleanSourceWith {
      src = builtins.path { path = ./robot-api; name = "robot-api"; };
      filter = path: type:
        !(pkgs.lib.hasSuffix ".tsbuildinfo" path)
        # keep dist; we need the compiled JS on the robot
        && !(pkgs.lib.hasInfix "/node_modules/" path)
        && !(pkgs.lib.hasInfix "/.git/" path);
    };

        robotApiPkg = pkgs.stdenv.mkDerivation {
      pname = "polyflow-robot-api";
      version = "0.1.0";

      src = robotApiSrc;

      buildInputs = [ pkgs.nodejs_22 ];
      nativeBuildInputs = [ pkgs.makeWrapper ];

      # No build in Nix for now; we assume dist/ is already in the repo.
      buildPhase = ''
        # no-op build
        :
      '';

      installPhase = ''
        mkdir -p $out/app $out/bin

        # Copy the app sources including dist/
        cp -R . $out/app

        # Wrapper script
        cat > $out/bin/robot-api <<EOF
        #!${pkgs.bash}/bin/bash
        set -euo pipefail
        cd "$out/app"
        exec ${pkgs.nodejs_22}/bin/node dist/main.js "\$@"
        EOF

        chmod +x $out/bin/robot-api
      '';
    };

    ############################################################################
    # ROS 2 workspace (Humble)
    ############################################################################

    rosPackageDirs = lib.filterAttrs (name: v: v == "directory" && name != "webrtc")
      (builtins.readDir workspaceSrcPath);

    rosWorkspacePackages = lib.mapAttrs (name: _: rosPkgs.buildRosPackage {
      pname = name;
      src   = pkgs.lib.cleanSource "${workspaceSrcPath}/${name}";
    }) rosPackageDirs;
    
    rosWorkspace = rosPkgs.buildROSWorkspace {
      name = "polyflow-ros-workspace";
      devPackages = rosWorkspacePackages;
    };

    rosWorkspaceEnv = pkgs.buildEnv {
      name = "polyflow-ros-env";
      paths = [ rosWorkspace ];
    };

    # Python (3.12) + helpers
    py = pkgs.python3;
    pyPkgs = py.pkgs or pkgs.python3Packages;
    sp = py.sitePackages;

    # Build a fixed osrf-pycommon (PEP 517), reusing nixpkgs' source
    osrfSrc = pkgs.python3Packages."osrf-pycommon".src;

    osrfFixed = pyPkgs.buildPythonPackage {
      pname   = "osrf-pycommon";
      version = "1.0.2-fixed";

      src       = osrfSrc;
      pyproject = true;

      nativeBuildInputs = with pyPkgs; [
        hatchling
        hatch-vcs
      ];

      propagatedBuildInputs = with pyPkgs; [
        setuptools
      ];
    };

    # Minimal Python environment for running webrtc + ROS Python bits
    pyEnv = py.withPackages (ps: [
      osrfFixed
      # add other shared Python deps here if needed
    ]);

    ############################################################################
    # WebRTC (Python) package for robot
    ############################################################################

    webrtcPkg = pkgs.stdenv.mkDerivation {
      pname = "polyflow-webrtc";
      version = "0.1.0";

      src = webrtcSrc;

      buildInputs = [ pyEnv ];
      dontBuild = true;

      installPhase = ''
        mkdir -p $out
        cp -R . $out/
      '';
    };

  in
  {
    # Export packages
    packages.${system} = {
      webrtcPkg        = webrtcPkg;
      robotConsoleStatic = robotConsoleStatic;
      robotApiPkg      = robotApiPkg;
      rosWorkspace     = rosWorkspace;
      rosWorkspaceEnv  = rosWorkspaceEnv;
    };

    # Full NixOS config for Pi 4 (sd-image)
    nixosConfigurations.rpi4 = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit webrtcPkg webrtcEnv pyEnv robotConsoleStatic robotApiPkg rosWorkspace rosWorkspaceEnv;
      };
      modules = [
        ({ ... }: {
          nixpkgs.overlays =
            rosOverlays ++ [ rosWorkspaceOverlay pinPython312 ];
        })
        nixos-hardware.nixosModules.raspberry-pi-4
        ./configuration.nix
      ];
    };
  };
}
