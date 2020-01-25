{ # The files would be going to ~/.config/doom (~/.doom.d)
  doomPrivateDir
  /* Extra packages to install

     Useful for non-emacs packages containing emacs bindings (e.g.
     mu4e).

     Example:
       extraPackages = epkgs: [ pkgs.mu ];
  */
, extraPackages ? epkgs: []
  /* Extra configuration to source during initialization

     Use this to refer other nix derivations.

     Example:
       extraConfig = ''
         (setq mu4e-mu-binary = "${pkgs.mu}/bin/mu")
       '';
  */
, extraConfig ? ""
  /* Package set to install emacs and dependent packages from

     Only used to get emacs package, if `bundledPackages` is set.
  */
, emacsPackages
  /* Use bundled revision of github.com/nix-community/emacs-overlay
     as `emacsPackages`.
  */
, bundledPackages ? true
  /* Override dependency versions

     Hadful for testing out updated dependencies without publishing
     a new version of them.

     Type: dependencyOverrides :: attrset -> either path derivation

     Example:
       dependencyOverrides = {
         "emacs-overlay" = fetchFromGitHub { owner = /* ...*\/; };
       };
  */
, dependencyOverrides ? { }
, lib
, pkgs
, stdenv
, buildEnv
, makeWrapper
, runCommand
, fetchFromGitHub
, substituteAll
, writeScriptBin
, writeTextDir }:

let
  lock = pkgs.callPackage
    "${builtins.fetchTarball https://github.com/vlaci/nix-lock/archive/develop.tar.gz}/lock.nix" {
      path = ./derivations.lock;
      overrides = dependencyOverrides;
    };

  # Packages we need to get the default doom configuration run
  overrides = self: super: {
    evil-escape = super.evil-escape.overrideAttrs (esuper: {
      patches = [ ./evil-escape.patch ];
    });
    evil-markdown = self.trivialBuild rec {
      pname = "evil-markdown";
      version = "1";
      recipe = null;
      ename = pname;
      src = lock.get pname;
      buildPhase = ":";
    };
    evil-org = self.trivialBuild rec {
      pname = "evil-org-mode";
      version = "1";
      recipe = null;
      ename = pname;
      src = lock.get pname;
      buildPhase = ":";
    };
    evil-quick-diff = self.trivialBuild rec {
      pname = "evil-quick-diff";
      version = "1";
      recipe = null;
      ename = pname;
      src = lock.get pname;
      buildPhase = ":";
    };
    org-yt = self.trivialBuild rec {
      pname = "org-yt";
      version = "1";
      recipe = null;
      ename = pname;
      src = lock.get pname;
    };
    php-extras = self.trivialBuild rec {
      pname = "php-extras";
      version = "1";
      recipe = null;
      ename = pname;
      src = lock.get pname;
      buildPhase = ":";
    };
    so-long = self.trivialBuild rec {
      pname = "so-long";
      version = "1";
      recipe = null;
      ename = "emacs-so-long";
      src = lock.get pname;
    };
  };

  # Stage 1: prepare source for byte-compilation
  doomSrc = stdenv.mkDerivation {
    name = "doom-src";
    src = lock.get "doom-emacs";
    phases = ["unpackPhase" "patchPhase" "installPhase"];
    patches = [
      (substituteAll {
        src = ./fix-paths.patch;
        private = builtins.toString doomPrivateDir;
      })
    ];
    installPhase = ''
      mkdir -p $out
      cp -r * $out
    '';
  };

  # Bundled version of `emacs-overlay`
  emacs-overlay = import (lock.get "emacs-overlay") pkgs pkgs;

  # Stage 2: install dependencies and byte-compile prepared source
  doomLocal =
    let
      straight-env = pkgs.callPackage (lock.get "nix-straight.el") {
        emacsPackages =
          if bundledPackages then
            let
              epkgs = emacs-overlay.emacsPackagesFor emacsPackages.emacs;
            in epkgs.overrideScope' overrides
          else
            emacsPackages.overrideScope' overrides;
        emacs = emacsPackages.emacsWithPackages extraPackages;
        emacsLoadFiles = [ ./advice.el ];
        emacsArgs = [
          "--"
          "install"
        ];

      # Need to reference a store path here, as byte-compilation will bake-in
      # absolute path to source files.
        emacsInitFile = "${doomSrc}/bin/doom";
      };

      packages = straight-env.packageList (super: {
        phases = [ "installPhase" ];
        preInstall = ''
          export DOOMDIR=${doomPrivateDir}
          export DOOMLOCALDIR=$(mktemp -d)/local/
        '';
      });

      # I don't know why but byte-compilation somehow triggers Emacs to look for
      # the git executable. It does not seem to be executed though...
      git = writeScriptBin "git" ''
        >&2 echo Executing git is not allowed; command line: "$@"
      '';
    in (straight-env.emacsEnv {
      inherit packages;
      straightDir = "$DOOMLOCALDIR/straight";
    }).overrideAttrs (super: {
      phases = [ "installPhase" ];
      buildInputs = super.buildInputs ++ [ git ];
      preInstall = ''
          export DOOMDIR=${doomPrivateDir}
          export DOOMLOCALDIR=$out/
      '';
    });

  # Stage 3: do additional fixups to refer compiled files in the store
  # and additional files in the users' home
  doom-emacs = stdenv.mkDerivation rec {
    name = "doom-emacs";
    src = doomSrc;
    patches = [
      (substituteAll {
        src = ./nix-integration.patch;
        local = doomLocal;
      })
    ];
    buildPhase = ":";
    installPhase = ''
      mkdir -p $out
      cp -r * $out
    '';
  };

  # Stage 4: `extraConfig` is merged into private configuration
  doomDir = pkgs.runCommand "doom-private" {
    inherit extraConfig;
    passAsFile = [ "extraConfig" ];
  } ''
      mkdir -p $out
      cp ${doomPrivateDir}/* $out
      chmod u+w $out/config.el
      cat $extraConfigPath >> $out/config.el
  '';

  # Stage 5: catch-all wrapper capable to run doom-emacs even
  # without installing ~/.emacs.d
  emacs = let
    load-config-from-site = writeTextDir "share/emacs/site-lisp/default.el" ''
      (message "doom-emacs is not placed in `doom-private-dir',
      loading from `site-lisp'")
      (when (> emacs-major-version 26)
            (load "${doom-emacs}/early-init.el"))
      (load "${doom-emacs}/init.el")
    '';
  in (emacsPackages.emacsWithPackages (epkgs: [
    load-config-from-site
  ]));
in
pkgs.runCommand "doom-emacs" {
  inherit emacs;
  buildInputs = [ emacs ];
  nativeBuildInputs = [ makeWrapper ];
} ''
    mkdir -p $out/bin
    for prog in $emacs/bin/*; do
      makeWrapper $prog $out/bin/$(basename $prog) --set DOOMDIR ${doomDir}
    done
    # emacsWithPackages assumes share/emacs/site-lisp/subdirs.el
    # exists, but doesn't pass it along.  When home-manager calls
    # emacsWithPackages again on this derivation, it fails due to
    # a dangling link to subdirs.el.
    # https://github.com/NixOS/nixpkgs/issues/66706
    ln -s ${emacs.emacs}/share $out
  ''
