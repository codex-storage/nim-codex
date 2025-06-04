{ pkgs }:

pkgs.fetchFromGitHub {
  owner = "nim-lang";
  repo = "sat";
  rev = "faf1617f44d7632ee9601ebc13887644925dcc01";
  # WARNING: Requires manual updates when Nim compiler version changes.
  hash = "sha256-JFrrSV+mehG0gP7NiQ8hYthL0cjh44HNbXfuxQNhq7c=";
}