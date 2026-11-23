{
  # Add with `imports = [ ... ]` inside the flake's nixosSystem.modules, e.g.
  #   inputs.<this-repo>.nixosModules.cmcc-jtydn-usb
  # The NUR name is `modules.cmcc-jtydn-usb` (plural), and it must not be imported
  # as `imports = [ pkgs.nur... ]` from a module file: `pkgs` is a module
  # argument, and `imports` is evaluated before arguments, which recurses.
  cmcc-jtydn-usb = import ./cmcc-jtydn-usb.nix;
}
