# The extraDirs contract, as buildable subjects.
#
# `extraDirs` entries are PATHS, not names: `share/assets` is the shape a Qt
# app asks for. Every loop in bundle.sh that turns one into a directory has to
# create the parent, and one of them did not -- Phase 6 staged the bundle into
# a temp dir with `cp -a "$out/$dir" "$test_dir/$dir"` and let cp fail on the
# missing parent, killing the build under `set -euo pipefail` with a bare
#
#   cp: cannot create directory '/build/tmp.XXXX/share/assets': No such file or directory
#
# and no ERROR line, no phase attribution. Flat entries never hit it, so the
# whole workspace's bundles were fine and only nested ones died.
#
# These live in the flake rather than in smoke.sh's `nix bundle` calls because
# the bundlers read `extraDirs` off the DERIVATION (`drv.extraDirs or []`), and
# a nixpkgs subject carries none -- there is no way to express this case
# through `nix bundle --bundler . nixpkgs#hello`.
{ pkgs, mkBundle }:

let
  inherit (pkgs) lib stdenv;
  soExt = if stdenv.hostPlatform.isDarwin then ".dylib" else ".so";

  # A subject with a real binary in bin/ (so the bundler has something to trace
  # and rewrite) plus one file per requested directory.
  subject = name: dirs: pkgs.runCommand "extra-dirs-${name}" { } (''
    mkdir -p $out/bin
    cp ${pkgs.hello}/bin/hello $out/bin/hello
  '' + lib.concatMapStrings (d: ''
    mkdir -p $out/${d}
    echo "payload for ${d}" > $out/${d}/note.txt
  '') dirs);

  # A library carrying a /nix/store path in its DATA section.
  #
  # Deliberately compiled rather than borrowed from nixpkgs: it has to be a
  # kind of non-portability that survives every rewriting phase, and load
  # commands, rpaths and NEEDED entries are all things Phase 3 fixes. A string
  # in .rodata is not, so Phase 6's binary-data scan is the only thing that can
  # object to this file -- which makes an objection proof that the scan read it.
  # runCommandCC, not runCommand: a plain runCommand's stdenv leaves $CC unset.
  dirtyLib = pkgs.runCommandCC "extra-dirs-dirty-lib" { } ''
    mkdir -p $out/lib
    cat > dirty.c <<'EOF'
    const char *baked =
      "/nix/store/00000000000000000000000000000000-extra-dirs-probe/share/data";
    int dirty_answer(void) { return 42; }
    EOF
    $CC -shared -fPIC -o $out/lib/libdirty${soExt} dirty.c
  '';

  dirtySubject = pkgs.runCommand "extra-dirs-dirty" { } ''
    mkdir -p $out/bin $out/share/probe
    cp ${pkgs.hello}/bin/hello $out/bin/hello
    cp ${dirtyLib}/lib/libdirty${soExt} $out/share/probe/
  '';

  nestedDirs = [ "share/assets" "share/deep/a/b" ];

  nestedBundle = mkBundle {
    drv = subject "nested" nestedDirs;
    name = "extra-dirs-nested";
    extraDirs = nestedDirs;
    guiApp = false;
    # hello's closure carries libraries with /nix/ paths baked into their data
    # sections (libiconv on Darwin). Those are a real but separate problem; if
    # they were errors here this subject could never go green and would say
    # nothing about extraDirs.
    warnOnBinaryData = true;
  };

in
{
  # Must BUILD: that is the regression gate on its own, because the bug was a
  # hard exit 1 in Phase 6's staging loop.
  #
  # The assertions below are about a different loop -- Phase 1's copy into
  # $out, which has the same parent-creation requirement and has always got it
  # right. They are here so that "the bundle built" cannot be satisfied by a
  # bundler that stops copying extraDirs at all.
  nested = pkgs.runCommand "check-extra-dirs-nested" { } ''
    b=${nestedBundle}
    fail() { echo "extraDirs contract: $1" >&2; exit 1; }

    [ -x "$b/bin/hello" ] || fail "bin/hello missing from the bundle"
    for d in ${lib.concatStringsSep " " nestedDirs}; do
      [ -f "$b/$d/note.txt" ] || fail "$d/note.txt missing -- a nested entry was not copied"
    done

    touch $out
  '';

  # Must FAIL, and must fail by NAMING the nested file.
  #
  # This is the other way Phase 6 could be wrong about a nested entry: stage it
  # nowhere and check nothing, which exits 0 and looks exactly like success.
  # Consumed by tests/smoke.sh, and deliberately NOT a check -- `nix flake
  # check` would build it and report the repo broken.
  #
  # The failure is over-determined: the dylib's install name is its own store
  # path, so the tracer also copies it to lib/ and Phase 6 reports it twice.
  # That is why smoke.sh greps for the `share/probe/` path specifically instead
  # of settling for a non-zero exit -- a bundler that staged nothing would
  # still fail here, on the lib/ copy alone.
  dirty = mkBundle {
    drv = dirtySubject;
    name = "extra-dirs-dirty";
    extraDirs = [ "share/probe" ];
    guiApp = false;
    # The point of the subject: make the baked-in path an ERROR, not a warning.
    warnOnBinaryData = false;
  };
}
