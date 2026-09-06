# Run once with:  Rscript install_r_packages.R
pkgs <- c(
  "sf", "spdep", "spatialreg", "Matrix",
  "dplyr", "readr", "tidyr", "stringr",
  "ggplot2", "car", "patchwork",
  "shiny", "leaflet",
  "rmapshaper"   # optional, used for faster/cleaner geometry simplification
)

installed <- rownames(installed.packages())
to_install <- setdiff(pkgs, installed)

if (length(to_install) > 0) {
  install.packages(to_install, repos = "https://cloud.r-project.org")
} else {
  message("All required R packages are already installed.")
}