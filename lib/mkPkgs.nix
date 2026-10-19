{ inputs, overlays, allowUnfreePredicate }:
system:

import inputs.nixpkgs {
  inherit system overlays;
  config = { inherit allowUnfreePredicate; };
}
