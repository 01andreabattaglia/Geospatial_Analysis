# Italian Municipal Tourism Explorer

A spatial-econometrics project studying how tourism demand (overnight stays) in
Italian municipalities relates to accommodation capacity, natural and cultural
endowments, and spatial spillovers from neighbouring municipalities. It combines
a **Python** data pipeline (ISTAT, OpenStreetMap and UNESCO sources merged into
one municipality-level dataset) with **R** spatial regression analyses (OLS,
SAR, SEM, SDM, SDEM, SLX) and an interactive **Shiny/leaflet** web app for
exploring the data, the estimated spillovers, and "what-if" scenarios.

![alt text](analysis/image.png)

---


## Quick start — run the interactive map

These are the minimum commands to get the Shiny app (`analysis/visualize_interactive_map.R`)
running. They assume the repository already ships the merged dataset at
`data/tourism_final_dataset.csv` and the ISTAT shapefile under
`data/input/ISTAT/`. If those files are not present, build them first with the
[full pipeline](#running-the-full-pipeline) below.

You need **Python 3.10+** (only for the data-prep pipeline, not required to
just view the map) and **R 4.2+** installed.

> **R must be reachable from the terminal.** Installing R does not
> automatically add it to your system `PATH`, especially on Windows — so
> `Rscript` may work inside RStudio but not in PowerShell/cmd/bash. If any
> `Rscript` command below fails with *"'Rscript' is not recognized"* (Windows)
> or *"command not found"* (Linux/macOS), see
> [Troubleshooting: Rscript not found](#troubleshooting-rscript-not-found)
> at the end of this section — or simplest fix, just open the project in
> **RStudio** and run the same commands from its built-in Terminal or
> Console instead of an external one.

### Linux / macOS

```bash
# 1. Clone the repository
git clone <repository-url>
cd <repository-folder>

# 2. (Optional, only if you need to rebuild the dataset) Python environment
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 3. Install the R packages used by the app and analyses
Rscript install_r_packages.R

# 4. Launch the interactive map
Rscript -e "shiny::runApp('analysis/visualize_interactive_map.R', launch.browser = TRUE)"
```

### Windows (PowerShell)

```powershell
# 1. Clone the repository
git clone <repository-url>
cd <repository-folder>

# 2. (Optional, only if you need to rebuild the dataset) Python environment
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt

# 3. Install the R packages used by the app and analyses
Rscript install_r_packages.R

# 4. Launch the interactive map
Rscript -e "shiny::runApp('analysis/visualize_interactive_map.R', launch.browser = TRUE)"
```

The app opens in your default browser (or prints a local URL such as
`http://127.0.0.1:xxxx` to the console). Loading and every subsequent
interaction re-runs the spatial model over the full national dataset, so give
each click a few seconds before clicking again (see
`docs/Interactive map.md` for the full usage guide).

#### Troubleshooting: `Rscript` not found

If R is installed but your terminal doesn't recognize `Rscript`, R's `bin`
folder simply isn't on your system `PATH`. Easiest fix — **run everything
from RStudio instead**: open the project in RStudio and use its built-in
**Terminal** tab (or the **Console**, prefixing commands with `system()`) to
run the same commands above; RStudio always knows where R lives regardless
of the system `PATH`.

If you'd rather fix it for your regular terminal (Windows):
1. Open R or RStudio and run `R.home("bin")` to get the exact install path,
   e.g. `C:/Program Files/R/R-4.3.3/bin/x64`.
2. In a **new** PowerShell window, add it to your user `PATH` permanently:
```powershell
   [System.Environment]::SetEnvironmentVariable(
       "Path",
       $env:Path + ";C:\Program Files\R\R-4.3.3\bin\x64",
       "User"
   )
```
3. Close and reopen PowerShell, then confirm with `Rscript --version`.

**System-library note for `sf`/`geopandas`:** both `sf` (R) and `geopandas`
(Python) depend on GDAL/GEOS/PROJ.
- **Linux (Debian/Ubuntu):** `sudo apt-get install -y gdal-bin libgdal-dev libgeos-dev libproj-dev libudunits2-dev`
- **Windows:** the CRAN binary of `sf` and the `geopandas`/`pyogrio` wheels from PyPI bundle these libraries, so a plain `install.packages("sf")` / `pip install geopandas` normally works without extra steps. If you hit build errors, install R packages via the pre-built binaries (default on Windows) and consider installing Python's geospatial stack via `conda`/`mamba` instead of `pip`.

---

## Running the full pipeline

The project has two layers: a Python stage that builds
`data/tourism_final_dataset.csv` from raw ISTAT/OSM/UNESCO sources, and an R
stage that analyzes it.

### 1. Python — build the merged dataset

Run from the **project root**, with the virtual environment from the Quick
Start activated:

```bash
# Linux/macOS
python -m src.prepare_istat_data
python -m src.prepare_openstreetmap_data
python -m src.prepare_othersources_data
python -m src.prepare_dataset
```

```powershell
# Windows
python -m src.prepare_istat_data
python -m src.prepare_openstreetmap_data
python -m src.prepare_othersources_data
python -m src.prepare_dataset
```

Order matters: `istat_data.py`, `openstreetmap_data.py` and
`othersources_data.py` each write an intermediate CSV to `data/output/`
(`istat_dataset.csv`, `osm_dataset.csv`, `other_sources_dataset.csv`), and
`prepare_dataset.py` merges all three plus the raw ISTAT DBF/Excel tourism
data into the final `data/tourism_final_dataset.csv` used by every R script.
All raw inputs are expected under `data/input/...` exactly as referenced
inside the scripts (ISTAT shapefile/DBF/Excel/CSV, OSM GeoJSON/TSV extracts,
UNESCO CSV) — see `docs/OpenStreetMap Overpass queries.md` for how the OSM
extracts were produced.

### 2. R — statistical analyses

Each analysis script fits an OLS baseline plus spatial models (SAR, SEM, SDM,
SDEM, SLX) on the merged dataset and saves plots as PNGs. **Working
directory matters** — the RQ scripts expect to be run from the **project
root** (they read `data/tourism_final_dataset.csv`), same for Shiny App.

```bash
# from the project root
Rscript analysis/RQ-1/RQ-1_Analysis.R
Rscript analysis/RQ-2/RQ-2_Analysis.R
Rscript analysis/RQ-3/RQ-3 Analysis.R
```

Outputs are written next to each script (e.g. `analysis/RQ-1/moran_scatterplot.png`,
`analysis/RQ-1/lisa_map.png`, `analysis/RQ-2/ols_vs_sdm_residuals.png`,
`analysis/RQ-3/sdm_direct_indirect_impacts.png`,
`analysis/RQ-3/spillover_map_nature.png`).

- **RQ-1** — Is tourism demand (overnight stays) spatially autocorrelated
  across Italian municipalities, and are there statistically significant
  geographical clusters of high- or low-demand municipalities? Tested via
  global and local (LISA) Moran's I.
- **RQ-2** — Which municipal endowments of cultural, natural, entertainment,
  and accessibility resources are associated with tourism demand, once
  spatial dependence in the data is accounted for? Tested by comparing OLS
  against spatial models (SAR/SEM/SDM/SDEM/SLX) and mapping residuals.
- **RQ-3** — Does a municipality's tourism endowment generate spillover
  effects on tourism demand in neighbouring municipalities, and are these
  effects complementary or competitive? Tested via direct/indirect/total
  impacts from the Spatial Durbin Model and a spillover map for
  nature-based resources.
- **Interactive map** (`analysis/visualize_interactive_map.R`) — the Shiny
  app described in the Quick Start.

---

## Project focus

The project asks whether a municipality's tourism attractiveness (overnight
stays) depends only on its own resources (accommodation capacity, coastline,
museums, sports facilities, nature-based sites, UNESCO status, etc.) or also
on what its **neighbouring municipalities** offer — i.e. whether tourism
demand exhibits **spatial spillovers** across Italy. It builds a
municipality-level panel by joining ISTAT administrative, tourism, and
population data with OpenStreetMap points/lines/polygons and UNESCO World
Heritage sites, then uses spatial econometric models (Moran's I/LISA, SAR,
SEM, SDM, SDEM, SLX) to test for spatial dependence and quantify direct vs.
indirect (spillover) effects. The Shiny app makes these results explorable
interactively, including a "what-if" simulator that propagates a change in
one municipality's resources through the fitted spatial model to the rest of
the country.