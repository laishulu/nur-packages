{ stdenv, lib, fetchurl, p7zip}:

let
  fontName = "SarasaTermSCNerd";
  fontVersion = "2.3.1";
  fontUrl = "https://github.com/laishulu/Sarasa-Term-SC-Nerd/releases/download/v${fontVersion}/${fontName}.ttc.7z";
  fontSha256 = "007knn1cbd224gglkv13ckyjq40diz4wprjlkyrzlzjbgygh2a5s"; # Replace with actual hash
in
  stdenv.mkDerivation {
    pname = fontName;
    version = fontVersion;

    src = fetchurl {
      url = fontUrl;
      sha256 = fontSha256;
    };

    nativeBuildInputs = [ p7zip ];

    unpackPhase = ''
      7z x $src
    '';

    installPhase = ''
      mkdir -p $out/share/fonts/truetype
      cp *.ttc $out/share/fonts/truetype/
    '';

    meta = with lib; {
      description = "Sarasa Term SC Nerd Font";
      homepage = "https://github.com/laishulu/Sarasa-Term-SC-Nerd";
      license = licenses.ofl;
      platforms = platforms.all;
      maintainers = [];
    };
  }
