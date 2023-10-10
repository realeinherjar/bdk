{
  description = "BDK Flake to run all tests locally and in CI";

  inputs = {
    # stable nixpkgs
    nixpkgs.url = "github:NixOS/nixpkgs/release-23.05";
    # pin bitcoind to a specific version
    # find instructions here:
    # <https://lazamar.co.uk/nix-versions>
    # pinned to 0.25.0
    nixpkgs-bitcoind.url = "github:nixos/nixpkgs?rev=9957cd48326fe8dbd52fdc50dd2502307f188b0d";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    flake-utils.url = "github:numtide/flake-utils";
    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nixpkgs-bitcoind, crane, rust-overlay, flake-utils, advisory-db, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        lib = pkgs.lib;
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        pkgs-bitcoind = import nixpkgs-bitcoind {
          inherit system overlays;
        };

        # Toolchains
        # latest stable
        rustTarget = pkgs.rust-bin.stable.latest.default;
        # we pin clippy instead of using "stable" so that our CI doesn't break
        # at each new cargo release
        rustClippyTarget = pkgs.rust-bin.stable."1.67.0".default;
        # MSRV
        rustMSRVTarget = pkgs.rust-bin.stable."1.57.0".default;
        # WASM
        rustWASMTarget = pkgs.rust-bin.stable.latest.default.override {
          targets = [ "wasm32-unknown-unknown" ];
        };

        # Rust configs
        craneLib = (crane.mkLib pkgs).overrideToolchain rustTarget;
        # Clippy specific configs
        craneClippyLib = (crane.mkLib pkgs).overrideToolchain rustClippyTarget;
        # MSRV specific configs
        # WASM specific configs
        # craneUtils needs to be built using Rust latest (not MSRV)
        # check https://github.com/ipetkov/crane/issues/422
        craneMSRVLib = ((crane.mkLib pkgs).overrideToolchain rustMSRVTarget).overrideScope' (final: prev: { inherit (craneLib) craneUtils; });
        craneWASMLib = ((crane.mkLib pkgs).overrideToolchain rustWASMTarget).overrideScope' (final: prev: { inherit (craneLib) craneUtils; });

        # Common inputs for all derivations
        buildInputs = [
          # Add additional build inputs here
          pkgs-bitcoind.bitcoind
          pkgs.electrs
          pkgs.openssl
          pkgs.openssl.dev
          pkgs.pkg-config
          pkgs.curl
          pkgs.libiconv
        ] ++ lib.optionals pkgs.stdenv.isDarwin [
          # Additional darwin specific inputs can be set here
          pkgs.darwin.apple_sdk.frameworks.Security
          pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          pkgs.darwin.apple_sdk.frameworks.CoreServices
        ];

        # WASM deps
        wasmInputs = [
          # Additional wasm specific inputs can be set here
          pkgs.wasm-bindgen-cli
          pkgs.clang_multi
        ];

        nativeBuildInputs = [
          # Add additional build inputs here
          pkgs.python3
        ] ++ lib.optionals pkgs.stdenv.isDarwin [
          # Additional darwin specific native inputs can be set here
        ];

        # Common derivation arguments used for all builds
        commonArgs = {
          # When filtering sources, we want to allow assets other than .rs files
          src = lib.cleanSourceWith {
            src = ./.; # The original, unfiltered source
            filter = path: type:
              # esplora uses `.md` in the source code
              (lib.hasSuffix "\.md" path) ||
              # bitcoin_rpc uses `.db` in the source code
              (lib.hasSuffix "\.db" path) ||
              # Default filter from crane (allow .rs files)
              (craneLib.filterCargoSources path type)
            ;
          };

          # Fixing name/version here to avoid warnings
          # This does not interact with the versioning
          # in any of bdk crates' Cargo.toml
          pname = "crates";
          version = "0.1.0";

          inherit buildInputs;
          inherit nativeBuildInputs;
          # Additional environment variables can be set directly
          BITCOIND_EXEC = "${pkgs.bitcoind}/bin/bitcoind";
          ELECTRS_EXEC = "${pkgs.electrs}/bin/electrs";
        };

        # MSRV derivation arguments
        MSRVArgs = {
          cargoLock = ./CargoMSRV.lock;
        };

        # WASM derivation arguments
        WASMArgs = {
          CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
          buildInputs = buildInputs ++ wasmInputs;
          inherit nativeBuildInputs;
        };


        # Caching: build *just* cargo dependencies for all crates, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        # all artifacts from running cargo {build,check,test} will be cached
        cargoArtifacts = craneLib.buildDepsOnly (commonArgs);
        cargoArtifactsMSRV = craneMSRVLib.buildDepsOnly (commonArgs // MSRVArgs);
        cargoArtifactsWASM = craneWASMLib.buildDepsOnly (commonArgs // WASMArgs);
        cargoArtifactsClippy = craneClippyLib.buildDepsOnly (commonArgs);

        # Run clippy on the workspace source,
        # reusing the dependency artifacts (e.g. from build scripts or
        # proc-macros) from above.
        clippy = craneClippyLib.cargoClippy (commonArgs // {
          cargoArtifacts = cargoArtifactsClippy;
          cargoClippyExtraArgs = "--all-features --all-targets -- -D warnings";
        });

        # fmt
        fmt = craneLib.cargoFmt (commonArgs // {
          inherit cargoArtifacts;
          cargoExtraArgs = "--all";
          rustFmtExtraArgs = "--config format_code_in_doc_comments=true";
        });
      in
      rec
      {
        checks = {
          inherit clippy;
          inherit fmt;
          # Latest
          latest = packages.default;
          latestAll = craneLib.cargoTest (commonArgs // {
            inherit cargoArtifacts;
            cargoTestExtraArgs = "--all-features -- --test-threads=2"; # bdk_bitcond_rpc test spams bitcoind
          });
          latestNoDefault = craneLib.cargoTest (commonArgs // {
            inherit cargoArtifacts;
            cargoTestExtraArgs = "--no-default-features -- --test-threads=2"; # bdk_bitcond_rpc test spams bitcoind
          });
          latestNoStdBdk = craneLib.cargoBuild (commonArgs // {
            inherit cargoArtifacts;
            cargoCheckExtraArgs = "-p bdk --no-default-features --features bitcoin/no-std,miniscript/no-std,bdk_chain/hashbrown";
          });
          latestNoStdChain = craneLib.cargoBuild (commonArgs // {
            inherit cargoArtifacts;
            cargoCheckExtraArgs = "-p bdk_chain --no-default-features --features bitcoin/no-std,miniscript/no-std,hashbrown";
          });
          latestNoStdEsplora = craneLib.cargoBuild (commonArgs // {
            inherit cargoArtifacts;
            cargoCheckExtraArgs = "-p bdk_esplora --no-default-features --features bitcoin/no-std,miniscript/no-std,bdk_chain/hashbrown";
          });
          # MSRV
          MSRV = packages.MSRV;
          MSRVAll = craneMSRVLib.cargoTest (commonArgs // MSRVArgs // {
            cargoArtifacts = cargoArtifactsMSRV;
            cargoTestExtraArgs = "--all-features -- --test-threads=2"; # bdk_bitcond_rpc test spams bitcoind
          });
          MSRVNoDefault = craneMSRVLib.cargoTest (commonArgs // MSRVArgs // {
            cargoArtifacts = cargoArtifactsMSRV;
            cargoTestExtraArgs = "--no-default-features -- --test-threads=2"; # bdk_bitcond_rpc test spams bitcoind
          });
          MSRVNoStdBdk = craneMSRVLib.cargoBuild (commonArgs // MSRVArgs // {
            cargoArtifacts = cargoArtifactsMSRV;
            cargoCheckExtraArgs = "-p bdk --no-default-features --features bitcoin/no-std,miniscript/no-std,bdk_chain/hashbrown";
          });
          MSRVNoStdChain = craneMSRVLib.cargoBuild (commonArgs // MSRVArgs // {
            cargoArtifacts = cargoArtifactsMSRV;
            cargoCheckExtraArgs = "-p bdk_chain --no-default-features --features bitcoin/no-std,miniscript/no-std,hashbrown";
          });
          MSRVNoStdEsplora = craneMSRVLib.cargoBuild (commonArgs // MSRVArgs // {
            cargoArtifacts = cargoArtifactsMSRV;
            cargoCheckExtraArgs = "-p bdk_esplora --no-default-features --features bitcoin/no-std,miniscript/no-std,bdk_chain/hashbrown";
          });
          # WASM
          WASMBdk = craneWASMLib.cargoBuild (commonArgs // WASMArgs // {
            cargoArtifacts = cargoArtifactsWASM;
            cargoCheckExtraArgs = "-p bdk --no-default-features --features bitcoin/no-std,miniscript/no-std,bdk_chain/hashbrown,dev-getrandom-wasm";
          });
          WASMEsplora = craneWASMLib.cargoBuild (commonArgs // WASMArgs // {
            cargoArtifacts = cargoArtifactsWASM;
            cargoCheckExtraArgs = "-p bdk_esplora --no-default-features --features bitcoin/no-std,miniscript/no-std,bdk_chain/hashbrown,async";
          });
          # Audit dependencies
          audit = craneLib.cargoAudit (commonArgs // {
            inherit advisory-db;
          });
        };

        packages = {
          # Building: does a cargo build
          default = craneLib.cargoBuild (commonArgs // {
            inherit cargoArtifacts;
          });
          MSRV = craneMSRVLib.cargoBuild (commonArgs // MSRVArgs // {
            cargoArtifacts = cargoArtifactsMSRV;
          });
          WASM = craneWASMLib.cargoBuild (commonArgs // WASMArgs // {
            cargoArtifacts = null;
          });
        };
        legacyPackages = {
          ci = {
            clippy = checks.clippy;
            fmt = checks.fmt;
            latest = {
              all = checks.latestAll;
              noDefault = checks.latestNoDefault;
              noStdBdk = checks.latestNoStdBdk;
              noStdChain = checks.latestNoStdChain;
              noStdEsplora = checks.latestNoStdEsplora;
            };
            MSRV = {
              all = checks.MSRVAll;
              noDefault = checks.MSRVNoDefault;
              noStdBdk = checks.MSRVNoStdBdk;
              noStdChain = checks.MSRVNoStdChain;
              noStdEsplora = checks.MSRVNoStdEsplora;
            };
          };
        };

        devShells = {
          default = craneLib.devShell {
            inherit cargoArtifacts;
            # inherit check build inputs
            checks = {
              clippy = checks.clippy;
              fmt = checks.fmt;
              default = checks.latest;
              all = checks.latestAll;
              noDefault = checks.latestNoDefault;
              noStdBdk = checks.latestNoStdBdk;
              noStdChain = checks.latestNoStdChain;
              noStdEsplora = checks.latestNoStdEsplora;
            };
            # dependencies
            packages = buildInputs ++ [
              pkgs.bashInteractive
              pkgs.git
              pkgs.ripgrep
              rustTarget
            ];

            BITCOIND_EXEC = commonArgs.BITCOIND_EXEC;
            ELECTRS_EXE = commonArgs.ELECTRS_EXE;
          };
          MSRV = craneMSRVLib.devShell {
            cargoArtifacts = cargoArtifactsMSRV;
            # inherit check build inputs
            checks = {
              clippy = checks.clippy;
              fmt = checks.fmt;
              default = checks.MSRV;
              all = checks.MSRVAll;
              noDefault = checks.MSRVNoDefault;
              noStdBdk = checks.MSRVNoStdBdk;
              noStdChain = checks.MSRVNoStdChain;
              noStdEsplora = checks.MSRVNoStdEsplora;
            };
            # dependencies
            packages = buildInputs ++ [
              pkgs.bashInteractive
              pkgs.git
              pkgs.ripgrep
              rustMSRVTarget
            ];

            BITCOIND_EXEC = commonArgs.BITCOIND_EXEC;
            ELECTRS_EXE = commonArgs.ELECTRS_EXE;
          };
          WASM = craneWASMLib.devShell {
            # inherit check build inputs
            checks = {
              clippy = checks.clippy;
              fmt = checks.fmt;
              default = checks.MSRV;
              all = checks.MSRVAll;
              noDefault = checks.MSRVNoDefault;
              noStdBdk = checks.MSRVNoStdBdk;
              noStdChain = checks.MSRVNoStdChain;
              noStdEsplora = checks.MSRVNoStdEsplora;
            };
            # dependencies
            packages = buildInputs ++ [
              pkgs.bashInteractive
              pkgs.git
              pkgs.ripgrep
              rustWASMTarget
            ];

            BITCOIND_EXEC = commonArgs.BITCOIND_EXEC;
            ELECTRS_EXEC = commonArgs.ELECTRS_EXEC;
            CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
          };
        };
      }
    );
}

          
