{ lib, stdenvNoCC, makeWrapper, git, jq, fontconfig, glib }:

stdenvNoCC.mkDerivation {
  pname = "infinityos-updater";
  version =
    let manifest = ./manifest.json;
    in if builtins.pathExists manifest
       then (lib.importJSON manifest).version
       else "0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 infinity-update.sh $out/bin/infinity-update
    wrapProgram $out/bin/infinity-update \
      --prefix PATH : ${lib.makeBinPath [ git jq fontconfig glib.bin ]}
    runHook postInstall
  '';

  meta = with lib; {
    description = "InfinityOS delta updater — installs GNOME extensions, fonts, icon themes and apps from the update repo";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "infinity-update";
  };
}
