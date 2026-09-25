# Two different libraries under one basename, and one binary needing both.
#
# nixpkgs on Darwin carries two libiconv.2.dylib (Apple's libiconv-109 and GNU
# libiconv-1.17). Staged by basename, the first one served both, and GNU's
# consumers (libidn2, libunistring) died on `Symbol not found: _libiconv`.
{ pkgs, mkBundle }:

let
  clash = tag: pkgs.runCommandCC "name-collision-clash-${tag}" { } ''
    mkdir -p $out/lib
    echo 'int clash_${tag}(void) { return 1; }' > clash.c
    $CC -dynamiclib -install_name $out/lib/libclash.dylib -o $out/lib/libclash.dylib clash.c
  '';
  user = tag: pkgs.runCommandCC "name-collision-use-${tag}" { } ''
    mkdir -p $out/lib
    echo 'int clash_${tag}(void); int use_${tag}(void) { return clash_${tag}(); }' > use.c
    $CC -dynamiclib -install_name $out/lib/libuse${tag}.dylib -o $out/lib/libuse${tag}.dylib \
      use.c ${clash tag}/lib/libclash.dylib
  '';
  subject = pkgs.runCommandCC "name-collision-subject" { } ''
    mkdir -p $out/bin
    cat > main.c <<'C'
    #include <stdio.h>
    int use_a(void);
    int use_b(void);
    int main(void) { printf("%d %d\n", use_a(), use_b()); return 0; }
    C
    $CC -o $out/bin/probe main.c ${user "a"}/lib/libusea.dylib ${user "b"}/lib/libuseb.dylib
  '';
  bundle = mkBundle {
    drv = subject;
    name = "name-collision";
    guiApp = false;
    warnOnBinaryData = true;
  };
in
pkgs.runCommand "check-name-collision" { } ''
  answer="$(${bundle}/bin/probe)" || { echo "the bundled probe did not start" >&2; exit 1; }
  [ "$answer" = "1 1" ] || { echo "unexpected answer: $answer" >&2; exit 1; }
  touch $out
''
