from __future__ import annotations

from pathlib import Path

import geopandas as gpd
import pandas as pd
from shapely.geometry import Point

METRIC_CRS = "EPSG:32632"
ISTAT_CODE_FIELD = "PRO_COM"
MUNICIPALITY_NAME_FIELD = "COMUNE"
COORDINATES_FIELD = "Coordinates"
UNESCO_NAME_FIELD = "Name EN"


def _parse_coordinates(coord_str) -> tuple[float, float] | None:
    """Converts a 'lat, lon' string from the UNESCO dataset into a (lat, lon) tuple."""
    if coord_str is None or (isinstance(coord_str, float) and pd.isna(coord_str)):
        return None
    try:
        lat_str, lon_str = str(coord_str).split(",")
        return float(lat_str.strip()), float(lon_str.strip())
    except (ValueError, AttributeError):
        return None


class OtherSources:
    """Each `add_*` method works on the internal `self.dataset` dataset.

    Typical usage::

        other_sources = OtherSources()
        other_sources.load_municipalities(path_shp)
        other_sources.add_UNESCO_sites(path_csv)
        other_sources.save_to_csv(path_csv)

    There is no longer any need to pass/reassign the DataFrame between one
    method and the next: each one reads and updates `self.dataset` in-place
    and returns `self`, so calls can also be chained if desired, but this
    is not mandatory.
    """

    def __init__(self) -> None:
        self._municipalities_shp_path: Path | None = None
        self.dataset: pd.DataFrame | None = None

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _require_dataset(self, caller_name: str) -> None:
        if self.dataset is None or self._municipalities_shp_path is None:
            raise RuntimeError(
                f"Dataset not initialized. Call load_municipalities() before {caller_name}()."
            )

    # ------------------------------------------------------------------
    # Base loading
    # ------------------------------------------------------------------

    def load_municipalities(self, municipalities_shp_path: str | Path) -> "OtherSources":
        municipalities_shp_path = Path(municipalities_shp_path)
        if not municipalities_shp_path.exists():
            raise FileNotFoundError(f"Municipalities shapefile not found: {municipalities_shp_path}")

        gdf = gpd.read_file(municipalities_shp_path)

        missing = [c for c in (ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD) if c not in gdf.columns]
        if missing:
            raise ValueError(
                f"Expected fields not found in the shapefile: {missing}. "
                f"Available columns: {list(gdf.columns)}"
            )

        if gdf.crs is None:
            raise ValueError("The shapefile does not have a defined CRS (check the .prj file).")

        self._municipalities_shp_path = municipalities_shp_path

        df = pd.DataFrame(gdf.drop(columns="geometry"))
        self.dataset = df.select_dtypes(include=["number", "object"])
        return self

    # ------------------------------------------------------------------
    # Methods that attach new columns to self.dataset
    # ------------------------------------------------------------------

    def add_UNESCO_sites(
        self,
        unesco_csv_path: str | Path,
    ) -> "OtherSources":
        self._require_dataset("add_UNESCO_sites")

        unesco_csv_path = Path(unesco_csv_path)
        if not unesco_csv_path.exists():
            raise FileNotFoundError(f"UNESCO sites CSV not found: {unesco_csv_path}")

        # Reload the geometry from the shapefile for internal use
        municipalities_gdf = gpd.read_file(self._municipalities_shp_path)
        municipalities = municipalities_gdf[[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD, "geometry"]].to_crs(METRIC_CRS)

        # Filter only the municipalities present in the input dataset
        municipalities = municipalities[municipalities[ISTAT_CODE_FIELD].isin(self.dataset[ISTAT_CODE_FIELD])]

        unesco = pd.read_csv(unesco_csv_path)

        if COORDINATES_FIELD not in unesco.columns:
            raise ValueError(
                f"Field '{COORDINATES_FIELD}' not found in the UNESCO CSV. "
                f"Available columns: {list(unesco.columns)}"
            )

        name_field = UNESCO_NAME_FIELD if UNESCO_NAME_FIELD in unesco.columns else unesco.columns[0]

        parsed_coords = unesco[COORDINATES_FIELD].apply(_parse_coordinates)
        unesco = unesco[parsed_coords.notna()].copy()
        parsed_coords = parsed_coords[parsed_coords.notna()]

        lat = parsed_coords.apply(lambda t: t[0])
        lon = parsed_coords.apply(lambda t: t[1])

        unesco_gdf = gpd.GeoDataFrame(
            unesco[[name_field]].rename(columns={name_field: "unesco_site_name"}),
            geometry=[Point(x, y) for x, y in zip(lon, lat)],
            crs="EPSG:4326",
        )
        unesco_gdf = unesco_gdf.to_crs(METRIC_CRS)

        # Spatial inner join: UNESCO points falling within municipality boundaries
        joined = gpd.sjoin(
            unesco_gdf,
            municipalities[[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD, "geometry"]],
            how="inner",
            predicate="within",
        )

        # The count must be computed BEFORE turning the names into a single
        # string: some UNESCO site names contain commas within them
        # (e.g. "Cathedral, Torre Civica and Piazza Grande, Modena" is ONE
        # single site), so the count cannot be derived by re-splitting the
        # joined string.
        sites_per_municipality = (
            joined.groupby([ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD])
            .agg(
                unesco_sites=(
                    "unesco_site_name",
                    lambda names: "; ".join(sorted(set(names))),
                ),
                n_unesco_sites=("unesco_site_name", "nunique"),
            )
            .reset_index()
        )

        result = self.dataset[[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD]].merge(
            sites_per_municipality, on=[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD], how="left"
        )
        result["unesco_sites"] = result["unesco_sites"].fillna("")
        result["n_unesco_sites"] = result["n_unesco_sites"].fillna(0).astype(int)

        self.dataset = (
            result.rename(columns={ISTAT_CODE_FIELD: "istat_code", MUNICIPALITY_NAME_FIELD: "municipality"})
            .sort_values("istat_code")
            .reset_index(drop=True)
        )
        return self

    # ------------------------------------------------------------------
    # Output
    # ------------------------------------------------------------------

    def save_to_csv(self, output_csv_path: str | Path) -> "OtherSources":
        self._require_dataset("save_to_csv")
        output_csv_path = Path(output_csv_path)
        output_csv_path.parent.mkdir(parents=True, exist_ok=True)
        self.dataset.to_csv(output_csv_path, index=False, encoding="utf-8")
        return self