# A sealed macOS bundle is carried byte for byte, while the files around it are still rewritten.
#
# The subject holds a tiny .app sealed by rcodesign (ad hoc, hardened runtime, Info.plist bound,
# Contents/_CodeSignature/CodeResources), which is how a signed helper reaches a module's lib/,
# and hello in bin/ as the control: Phase 3 must still rewrite that one.
{ pkgs, mkBundle }:

let
  probeApp = pkgs.runCommandCC "sealed-probe-app" { nativeBuildInputs = [ pkgs.rcodesign ]; } ''
    app=$out/lib/Probe.app
    mkdir -p $app/Contents/MacOS
    echo 'int main(void) { return 0; }' > probe.c
    $CC -o $app/Contents/MacOS/probe probe.c
    cat > $app/Contents/Info.plist <<'EOF'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>probe</string>
      <key>CFBundleIdentifier</key><string>co.logos.SealedProbe</string>
      <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>
    EOF
    rcodesign sign --code-signature-flags runtime $app
    test -f $app/Contents/_CodeSignature/CodeResources
  '';

  subject = pkgs.runCommand "sealed-bundle-subject" { } ''
    mkdir -p $out/bin $out/lib
    cp ${pkgs.hello}/bin/hello $out/bin/hello
    cp -R ${probeApp}/lib/Probe.app $out/lib/
  '';

  bundle = mkBundle {
    drv = subject;
    name = "sealed-bundle";
    guiApp = false;
    # hello's libiconv carries /nix/ strings in its data; not what this test is about.
    warnOnBinaryData = true;
  };
in
{
  carried = pkgs.runCommand "sealed-bundle-carried" { nativeBuildInputs = [ pkgs.darwin.cctools ]; } ''
    diff -r --no-dereference ${probeApp}/lib/Probe.app ${bundle}/lib/Probe.app
    echo "the sealed bundle is byte for byte the subject's"
    # The control only means something if hello started out loading from the store.
    otool -L ${subject}/bin/hello | tail -n +2 | grep -q /nix/store
    if otool -L ${bundle}/bin/hello | tail -n +2 | grep -q /nix/store; then
      echo "FAIL: bin/hello still loads from /nix/store, so Phase 3 never ran" >&2
      exit 1
    fi
    echo "bin/hello was rewritten around it"
    touch $out
  '';
}
