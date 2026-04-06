{
  description = "TobiiFree";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};

    # Helper: build a Zig application from applications/<name>/.
    mkZigApp = {
      name,
      dir,
      nativeBuildInputs ? [],
      buildInputs ? [],
    }:
      pkgs.stdenv.mkDerivation {
        pname = name;
        version = "0.1.0";
        src = ./.;

        nativeBuildInputs = [pkgs.zig pkgs.pkg-config] ++ nativeBuildInputs;
        inherit buildInputs;

        dontConfigure = true;
        dontInstall = true;

        buildPhase = ''
          # Zig needs a writable cache dir and home.
          export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
          export HOME=$TMPDIR

          cd ${dir}
          zig build -Doptimize=ReleaseSafe \
            --prefix $out \
            --cache-dir $ZIG_GLOBAL_CACHE_DIR
        '';
      };

    tobiifreed = mkZigApp {
      name = "tobiifreed";
      dir = "applications/tobiifreed";
      buildInputs = [pkgs.libusb1];
    };

    tobiifree-overlay = mkZigApp {
      name = "tobiifree-overlay";
      dir = "applications/tobiifree-overlay";
      buildInputs = [pkgs.libusb1 pkgs.gtk4 pkgs.gtk4-layer-shell];
    };

    # Static SPA: wasm build → bundle → npm install → vite build.
    tobiifree-demo = pkgs.buildNpmPackage {
      pname = "tobiifree-demo";
      version = "0.1.0";
      src = ./.;

      npmDepsHash = "sha256-JbJV9/AtkRFMZtIdp9N+A4rERZ5uSidZ6X2JsVZvNXA=";
      nativeBuildInputs = [pkgs.zig];
      # The `usb` npm package (node-gyp native addon) is only needed for
      # Node.js usage; the browser SPA uses WebUSB. Skip native builds.
      npmFlags = ["--ignore-scripts"];

      # Build wasm core + embed into TS SDK before the npm build phase.
      preBuild = ''
        export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
        cd driver && zig build -Doptimize=ReleaseSmall \
          --cache-dir $ZIG_GLOBAL_CACHE_DIR
        cd ..
        node scripts/bundle-wasm.mjs
      '';

      # The root package.json has no build script; drive vite directly.
      buildPhase = ''
        runHook preBuild
        cd applications/tobiifree-demo
        npx vite build
        cd ../..
        runHook postBuild
      '';

      installPhase = ''
        cp -r applications/tobiifree-demo/dist $out
      '';

      dontNpmBuild = true;
    };
  in {
    packages.${system} = {
      inherit tobiifreed tobiifree-overlay tobiifree-demo;
      default = tobiifreed;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        just
        # build tools
        gcc
        gnumake
        pkg-config
        # usb / runtime
        libusb1
        usbutils
        gusb
        # debugging
        strace
        ltrace
        gdb
        # web / wasm
        zig
        nodejs
        python3
        inotify-tools
        moreutils
        # native overlay (GTK4 + layer-shell)
        gtk4
        gtk4-layer-shell
        gobject-introspection
      ];
    };
  };
}
