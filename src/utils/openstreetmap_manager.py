from __future__ import annotations

import unicodedata
from pathlib import Path

import geopandas as gpd
from shapely.geometry import Point
import pandas as pd
from shapely.geometry import GeometryCollection, LineString, MultiLineString
from shapely.ops import linemerge

METRIC_CRS = "EPSG:32632"
ISTAT_CODE_FIELD = "PRO_COM"
MUNICIPALITY_NAME_FIELD = "COMUNE"
BOUNDARY_BUFFER_METERS = 50


def _extract_lines(geom):
    if geom is None or geom.is_empty:
        return None
    if isinstance(geom, (LineString, MultiLineString)):
        return geom
    if isinstance(geom, GeometryCollection):
        lines = [g for g in geom.geoms if isinstance(g, (LineString, MultiLineString))]
        if not lines:
            return None
        merged = linemerge(lines) if len(lines) > 1 else lines[0]
        return merged
    return None


def _normalize_name(name) -> str | None:
    if name is None or (isinstance(name, float) and pd.isna(name)):
        return None
    normalized = unicodedata.normalize("NFKD", str(name))
    normalized = "".join(c for c in normalized if not unicodedata.combining(c))
    return normalized.strip().lower()


class OpenStreetMap:
    """Each `add_*` method works on the internal `self.dataset` dataset.

    Typical usage::

        osm = OpenStreetMap()
        osm.load_municipalities(path_shp)
        osm.add_sea_coast_line(path_geojson)
        osm.add_lake_coast_line(path_geojson)
        ...
        osm.save_to_csv(path_csv)

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

    def _merge_column(
        self,
        new_col_df: pd.DataFrame,
        col: str,
        fill_value=0,
        round_ndigits: int | None = None,
        as_int: bool = False,
    ) -> None:
        """Attach a new column (indexed by istat_code) to self.dataset."""
        self.dataset = self.dataset.merge(
            new_col_df[["istat_code", col]], on="istat_code", how="left"
        )
        self.dataset[col] = self.dataset[col].fillna(fill_value)
        if round_ndigits is not None:
            self.dataset[col] = self.dataset[col].round(round_ndigits)
        if as_int:
            self.dataset[col] = self.dataset[col].astype(int)

    def _load_municipalities_metric(self) -> gpd.GeoDataFrame:
        return gpd.read_file(self._municipalities_shp_path).to_crs(METRIC_CRS)

    # ------------------------------------------------------------------
    # Base loading
    # ------------------------------------------------------------------

    def load_municipalities(self, municipalities_shp_path: str | Path) -> "OpenStreetMap":
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

        df = pd.DataFrame(gdf.drop(columns="geometry")).select_dtypes(include=["number", "object"])

        self.dataset = (
            df[[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD]]
            .rename(columns={ISTAT_CODE_FIELD: "istat_code", MUNICIPALITY_NAME_FIELD: "municipality"})
            .sort_values("istat_code")
            .reset_index(drop=True)
        )
        return self

    # ------------------------------------------------------------------
    # Methods that attach new columns to self.dataset
    # ------------------------------------------------------------------

    def add_sea_coast_line(self, coastline_geojson_path: str | Path) -> "OpenStreetMap":
        self._require_dataset("add_sea_coast_line")

        coastline_geojson_path = Path(coastline_geojson_path)
        if not coastline_geojson_path.exists():
            raise FileNotFoundError(f"Coastline GeoJSON not found: {coastline_geojson_path}")

        municipalities_gdf = gpd.read_file(self._municipalities_shp_path)
        municipalities = municipalities_gdf[[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD, "geometry"]].to_crs(METRIC_CRS)
        municipalities = municipalities[municipalities[ISTAT_CODE_FIELD].isin(self.dataset["istat_code"])]

        coastline = gpd.read_file(coastline_geojson_path)
        if coastline.crs is None:
            coastline = coastline.set_crs("EPSG:4326")

        coastline = coastline[coastline.geometry.notna()]
        coastline = coastline[
            coastline.geom_type.isin(["LineString", "MultiLineString", "Polygon", "MultiPolygon"])
        ]

        coastline = coastline.to_crs(METRIC_CRS)
        coastline["geometry"] = coastline.geometry.apply(
            lambda geom: geom.boundary if geom.geom_type in ("Polygon", "MultiPolygon") else geom
        )

        for col in ("city:left", "city:right"):
            if col not in coastline.columns:
                coastline[col] = None

        has_tag = coastline["city:left"].notna() | coastline["city:right"].notna()
        coastline_tagged = coastline[has_tag].copy()
        coastline_untagged = coastline[~has_tag].copy()

        municipalities_lookup = municipalities[[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD]].copy()
        municipalities_lookup["_name_key"] = municipalities_lookup[MUNICIPALITY_NAME_FIELD].apply(_normalize_name)

        tagged_rows = []
        for _, row in coastline_tagged.iterrows():
            length_km = row.geometry.length / 1000.0
            for side in ("city:left", "city:right"):
                city_name = row[side]
                if city_name is None or (isinstance(city_name, float) and pd.isna(city_name)):
                    continue
                tagged_rows.append({"_name_key": _normalize_name(city_name), "sea_coast_km": length_km})

        coast_from_tags = pd.DataFrame(tagged_rows, columns=["_name_key", "sea_coast_km"])
        coast_from_tags = coast_from_tags.groupby("_name_key", as_index=False)["sea_coast_km"].sum()

        coast_from_overlay = pd.DataFrame(columns=[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD, "sea_coast_km"])
        if len(coastline_untagged) > 0:
            municipalities_buffered = municipalities.copy()
            municipalities_buffered["geometry"] = municipalities_buffered.geometry.buffer(BOUNDARY_BUFFER_METERS)

            intersection = gpd.overlay(
                coastline_untagged[["geometry"]],
                municipalities_buffered[[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD, "geometry"]],
                how="intersection",
                keep_geom_type=False,
            )
            intersection["geometry"] = intersection.geometry.apply(_extract_lines)
            intersection = intersection[intersection.geometry.notna()]
            intersection["sea_coast_km"] = intersection.geometry.length / 1000.0

            coast_from_overlay = (
                intersection.groupby([ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD])["sea_coast_km"]
                .sum()
                .reset_index()
            )

        coast_tagged_by_municipality = municipalities_lookup.merge(coast_from_tags, on="_name_key", how="inner")
        coast_tagged_by_municipality = coast_tagged_by_municipality[[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD, "sea_coast_km"]]

        coast_combined = pd.concat([coast_tagged_by_municipality, coast_from_overlay], ignore_index=True)
        coast_per_municipality = (
            coast_combined.groupby([ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD])["sea_coast_km"]
            .sum()
            .reset_index()
            .rename(columns={ISTAT_CODE_FIELD: "istat_code"})
        )

        self._merge_column(coast_per_municipality, "sea_coast_km", fill_value=0.0, round_ndigits=3)
        return self

    def add_lake_coast_line(self, lake_geojson_path: str | Path) -> "OpenStreetMap":
        self._require_dataset("add_lake_coast_line")

        lake_geojson_path = Path(lake_geojson_path)
        if not lake_geojson_path.exists():
            raise FileNotFoundError(f"Lake GeoJSON not found: {lake_geojson_path}")

        municipalities = self._load_municipalities_metric()

        lake = gpd.read_file(lake_geojson_path)
        if lake.crs is None:
            lake = lake.set_crs("EPSG:4326")

        lake = lake[lake.geometry.notna()]
        lake = lake[lake.geom_type.isin(["Polygon", "MultiPolygon", "LineString", "MultiLineString"])]
        if lake.empty:
            raise ValueError("The lake GeoJSON does not contain valid geometries.")

        lake = lake.to_crs(METRIC_CRS)
        lake["geometry"] = lake.geometry.apply(
            lambda geom: geom.boundary if geom.geom_type in ("Polygon", "MultiPolygon") else geom
        )

        municipalities_buffered = municipalities[[ISTAT_CODE_FIELD, "geometry"]].copy()
        municipalities_buffered["geometry"] = municipalities_buffered.geometry.buffer(BOUNDARY_BUFFER_METERS)

        intersection = gpd.overlay(
            lake[["geometry"]],
            municipalities_buffered,
            how="intersection",
            keep_geom_type=False,
        )
        intersection["geometry"] = intersection.geometry.apply(_extract_lines)
        intersection = intersection[intersection.geometry.notna()]
        intersection["lake_coast_km"] = (intersection.geometry.length / 1000.0).round(3)

        coast_per_municipality = (
            intersection.groupby(ISTAT_CODE_FIELD)["lake_coast_km"]
            .sum()
            .round(3)
            .reset_index()
            .rename(columns={ISTAT_CODE_FIELD: "istat_code"})
        )

        self._merge_column(coast_per_municipality, "lake_coast_km", fill_value=0.0, round_ndigits=3)
        return self

    def add_protected_areas(self, parks_geojson_path: str | Path) -> "OpenStreetMap":
        self._require_dataset("add_protected_areas")

        parks_geojson_path = Path(parks_geojson_path)
        if not parks_geojson_path.exists():
            raise FileNotFoundError(f"Protected areas GeoJSON not found: {parks_geojson_path}")

        municipalities = self._load_municipalities_metric()

        parks = gpd.read_file(parks_geojson_path)
        if parks.crs is None:
            parks = parks.set_crs("EPSG:4326")

        parks = parks[parks.geometry.notna()]
        parks = parks[parks.geom_type.isin(["Polygon", "MultiPolygon"])]
        if parks.empty:
            raise ValueError("The protected areas GeoJSON does not contain valid polygon geometries.")

        parks = parks.to_crs(METRIC_CRS)

        intersection = gpd.overlay(
            parks[["geometry"]],
            municipalities[[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD, "geometry"]],
            how="intersection",
            keep_geom_type=False,
        )
        intersection = intersection[intersection.geom_type.isin(["Polygon", "MultiPolygon"])]
        intersection["protected_areas_sqkm"] = (intersection.geometry.area / 1_000_000.0).round(3)

        area_per_municipality = (
            intersection.groupby(ISTAT_CODE_FIELD)["protected_areas_sqkm"]
            .sum()
            .round(3)
            .reset_index()
            .rename(columns={ISTAT_CODE_FIELD: "istat_code"})
        )

        self._merge_column(area_per_municipality, "protected_areas_sqkm", fill_value=0.0, round_ndigits=3)
        return self

    def _add_point_based_count(
        self,
        tsv_path: str | Path,
        col_name: str,
        caller_name: str,
        keep_cols_candidates: list[str],
        filter_fn=None,
        require_message: str | None = None,
    ) -> None:
        """Common factory for all 'count OSM points per municipality' methods."""
        self._require_dataset(caller_name)

        tsv_path = Path(tsv_path)
        if not tsv_path.exists():
            raise FileNotFoundError(f"TSV not found: {tsv_path}")

        municipalities = self._load_municipalities_metric()

        df = pd.read_csv(tsv_path, sep="\t", dtype={"@id": str})

        required_cols = {"@lat", "@lon"}
        missing_cols = required_cols - set(df.columns)
        if missing_cols:
            raise ValueError(f"Missing columns in the TSV: {sorted(missing_cols)}")

        if filter_fn is not None:
            df = filter_fn(df)

        df = df.dropna(subset=["@lat", "@lon"])
        df["@lat"] = pd.to_numeric(df["@lat"], errors="coerce")
        df["@lon"] = pd.to_numeric(df["@lon"], errors="coerce")
        df = df.dropna(subset=["@lat", "@lon"])

        if df.empty:
            raise ValueError(require_message or "The TSV does not contain valid records with valid coordinates.")

        geometry = gpd.points_from_xy(df["@lon"], df["@lat"])
        keep_cols = [c for c in keep_cols_candidates if c in df.columns] or ["@id"]
        gdf = gpd.GeoDataFrame(df[keep_cols], geometry=geometry, crs="EPSG:4326").to_crs(METRIC_CRS)

        joined = gpd.sjoin(
            gdf, municipalities[[ISTAT_CODE_FIELD, "geometry"]], how="left", predicate="within"
        )

        counts = (
            joined.groupby(ISTAT_CODE_FIELD)
            .size()
            .reset_index(name=col_name)
            .rename(columns={ISTAT_CODE_FIELD: "istat_code"})
        )
        counts[col_name] = counts[col_name].astype(int)

        self._merge_column(counts, col_name, fill_value=0, as_int=True)

    def add_historical_sites_and_museums(self, museums_tsv_path: str | Path) -> "OpenStreetMap":
        def _filter(df: pd.DataFrame) -> pd.DataFrame:
            return df[df["tourism"] == "museum"].copy()

        self._add_point_based_count(
            museums_tsv_path,
            col_name="museums",
            caller_name="add_historical_sites_and_museums",
            keep_cols_candidates=["@id", "name"],
            filter_fn=_filter,
            require_message=(
                "The museums TSV does not contain valid records with "
                "tourism == 'museum' and valid coordinates."
            ),
        )
        return self

    def add_architectural_features(self, architectural_poi_tsv_path: str | Path) -> "OpenStreetMap":
        # Dedicated handling for misaligned rows: reads everything as a string
        # and manually validates lat/lon before converting them, so any
        # corrupted rows are discarded without crashing the parsing.
        self._require_dataset("add_architectural_features")

        architectural_poi_tsv_path = Path(architectural_poi_tsv_path)
        if not architectural_poi_tsv_path.exists():
            raise FileNotFoundError(
                f"Architectural sites TSV not found: {architectural_poi_tsv_path}"
            )

        municipalities = self._load_municipalities_metric()

        poi_df = pd.read_csv(architectural_poi_tsv_path, sep="\t", dtype="string", low_memory=False)

        required_cols = {"@lat", "@lon"}
        missing = required_cols - set(poi_df.columns)
        if missing:
            raise ValueError(
                f"Expected fields not found in the TSV: {sorted(missing)}. "
                f"Available columns: {list(poi_df.columns)}"
            )

        n_total = len(poi_df)
        lat_numeric = pd.to_numeric(poi_df["@lat"], errors="coerce")
        lon_numeric = pd.to_numeric(poi_df["@lon"], errors="coerce")
        valid_mask = lat_numeric.notna() & lon_numeric.notna()

        n_invalid = n_total - valid_mask.sum()
        if n_invalid > 0:
            print(
                f"[add_architectural_features] Warning: discarded {n_invalid} rows out of "
                f"{n_total} due to non-numeric or misaligned coordinates "
                f"(check {architectural_poi_tsv_path})."
            )

        poi_df = poi_df[valid_mask].copy()
        poi_df["@lat"] = lat_numeric[valid_mask]
        poi_df["@lon"] = lon_numeric[valid_mask]

        if poi_df.empty:
            raise ValueError("The architectural sites TSV does not contain valid coordinates.")

        poi_gdf = gpd.GeoDataFrame(
            poi_df, geometry=gpd.points_from_xy(poi_df["@lon"], poi_df["@lat"]), crs="EPSG:4326"
        ).to_crs(METRIC_CRS)

        joined = gpd.sjoin(
            poi_gdf[["geometry"]],
            municipalities[[ISTAT_CODE_FIELD, "geometry"]],
            how="left",
            predicate="within",
        )

        poi_per_municipality = (
            joined.groupby(ISTAT_CODE_FIELD)
            .size()
            .reset_index(name="architectural_features")
            .rename(columns={ISTAT_CODE_FIELD: "istat_code"})
        )
        poi_per_municipality["architectural_features"] = poi_per_municipality["architectural_features"].astype(int)

        self._merge_column(poi_per_municipality, "architectural_features", fill_value=0, as_int=True)
        return self

    def add_sport_facilities(self, sport_facilities_tsv_path: str | Path) -> "OpenStreetMap":
        self._add_point_based_count(
            sport_facilities_tsv_path,
            col_name="sports_facilities",
            caller_name="add_sport_facilities",
            keep_cols_candidates=["@id", "name"],
            require_message=(
                "The sports facilities TSV does not contain valid records with valid coordinates."
            ),
        )
        return self

    def add_nature_based(self, nature_based_tsv_path: str | Path) -> "OpenStreetMap":
        self._add_point_based_count(
            nature_based_tsv_path,
            col_name="nature_based",
            caller_name="add_nature_based",
            keep_cols_candidates=["@id", "route", "leisure", "tourism", "amenity", "name"],
            require_message=(
                "The nature-based facilities TSV does not contain valid records with valid coordinates."
            ),
        )
        return self

    def add_theme_parks(self, theme_parks_tsv_path: str | Path) -> "OpenStreetMap":
        self._add_point_based_count(
            theme_parks_tsv_path,
            col_name="theme_parks",
            caller_name="add_theme_parks",
            keep_cols_candidates=[
                "@id", "tourism", "leisure", "name", "disused:tourism", "construction:tourism",
            ],
            require_message="The theme parks TSV does not contain valid records with valid coordinates.",
        )
        return self

    def add_nightlife(self, nightlife_tsv_path: str | Path) -> "OpenStreetMap":
        self._add_point_based_count(
            nightlife_tsv_path,
            col_name="nightlife",
            caller_name="add_nightlife",
            keep_cols_candidates=["@id", "amenity", "name"],
            require_message=(
                "The nightlife venues TSV does not contain valid records with valid coordinates."
            ),
        )
        return self

    def add_public_transport_points(self, public_transport_tsv_path: str | Path) -> "OpenStreetMap":
        """Add public transport points to the cumulative column.

        Designed to be called multiple times in sequence (e.g. once for
        North/Center/South): each call reads a SINGLE TSV and ADDS the
        count to the ``public_transport_points`` column already present in
        ``self.dataset``, without resetting previous counts.
        """
        self._require_dataset("add_public_transport_points")

        public_transport_tsv_path = Path(public_transport_tsv_path)
        if not public_transport_tsv_path.exists():
            raise FileNotFoundError(
                f"Public transport points TSV not found: {public_transport_tsv_path}"
            )

        municipalities = self._load_municipalities_metric()

        transport_df = pd.read_csv(public_transport_tsv_path, sep="\t", dtype={"@id": str})

        required_cols = {"@lat", "@lon"}
        missing_cols = required_cols - set(transport_df.columns)
        if missing_cols:
            raise ValueError(f"Missing columns in the public transport TSV: {sorted(missing_cols)}")

        transport_df = transport_df.dropna(subset=["@lat", "@lon"])
        transport_df["@lat"] = pd.to_numeric(transport_df["@lat"], errors="coerce")
        transport_df["@lon"] = pd.to_numeric(transport_df["@lon"], errors="coerce")
        transport_df = transport_df.dropna(subset=["@lat", "@lon"])

        if transport_df.empty:
            raise ValueError(
                "The public transport points TSV does not contain valid records with valid coordinates."
            )

        geometry = gpd.points_from_xy(transport_df["@lon"], transport_df["@lat"])
        keep_cols = [c for c in ["@id", "name"] if c in transport_df.columns] or ["@id"]
        transport_gdf = gpd.GeoDataFrame(
            transport_df[keep_cols], geometry=geometry, crs="EPSG:4326"
        ).to_crs(METRIC_CRS)

        joined = gpd.sjoin(
            transport_gdf, municipalities[[ISTAT_CODE_FIELD, "geometry"]], how="left", predicate="within"
        )

        points_per_municipality = (
            joined.groupby(ISTAT_CODE_FIELD)
            .size()
            .reset_index(name="new_public_transport_points")
            .rename(columns={ISTAT_CODE_FIELD: "istat_code"})
        )
        points_per_municipality["new_public_transport_points"] = points_per_municipality[
            "new_public_transport_points"
        ].astype(int)

        if "public_transport_points" not in self.dataset.columns:
            self.dataset["public_transport_points"] = 0

        self.dataset = self.dataset.merge(points_per_municipality, on="istat_code", how="left")
        self.dataset["new_public_transport_points"] = (
            self.dataset["new_public_transport_points"].fillna(0).astype(int)
        )
        self.dataset["public_transport_points"] = (
            self.dataset["public_transport_points"] + self.dataset["new_public_transport_points"]
        ).astype(int)
        self.dataset = self.dataset.drop(columns=["new_public_transport_points"])
        return self
    
    def add_airport_straight_distance(self, airports_tsv_path: str | Path) -> "OpenStreetMap":
        self._require_dataset("add_airport_straight_distance")

        airports_tsv_path = Path(airports_tsv_path)
        if not airports_tsv_path.exists():
            raise FileNotFoundError(f"Airports TSV not found: {airports_tsv_path}")

        municipalities = gpd.read_file(self._municipalities_shp_path).to_crs(METRIC_CRS)
        municipalities = municipalities[municipalities[ISTAT_CODE_FIELD].isin(self.dataset["istat_code"])]
        municipalities = municipalities.copy()
        municipalities["geometry"] = municipalities.geometry.centroid

        airports_df = pd.read_csv(airports_tsv_path, sep="\t", dtype={"@id": str})

        required_cols = {"@lat", "@lon"}
        missing_cols = required_cols - set(airports_df.columns)
        if missing_cols:
            raise ValueError(f"Missing columns in the airports TSV: {sorted(missing_cols)}")

        airports_df = airports_df.dropna(subset=["@lat", "@lon"])
        airports_df["@lat"] = pd.to_numeric(airports_df["@lat"], errors="coerce")
        airports_df["@lon"] = pd.to_numeric(airports_df["@lon"], errors="coerce")
        airports_df = airports_df.dropna(subset=["@lat", "@lon"])

        if airports_df.empty:
            raise ValueError("The airports TSV does not contain valid records with valid coordinates.")

        geometry = gpd.points_from_xy(airports_df["@lon"], airports_df["@lat"])
        airports_gdf = gpd.GeoDataFrame(airports_df[["@id"]], geometry=geometry, crs="EPSG:4326")
        airports_gdf = airports_gdf.to_crs(METRIC_CRS)

        # nearest-neighbor join: each municipality -> nearest airport + distance in meters
        joined = gpd.sjoin_nearest(
            municipalities[[ISTAT_CODE_FIELD, "geometry"]],
            airports_gdf[["geometry"]],
            how="left",
            distance_col="dist_m",
        )

        distance_df = (
            joined.groupby(ISTAT_CODE_FIELD)["dist_m"]
            .min()
            .reset_index()
            .rename(columns={ISTAT_CODE_FIELD: "istat_code"})
        )
        distance_df["airport_straight_km"] = (distance_df["dist_m"] / 1000.0).round(3)
        distance_df = distance_df.drop(columns=["dist_m"])

        self._merge_column(distance_df, "airport_straight_km", fill_value=None)
        return self

    # ------------------------------------------------------------------
    # Output
    # ------------------------------------------------------------------

    def save_to_csv(self, output_csv_path: str | Path) -> "OpenStreetMap":
        self._require_dataset("save_to_csv")
        output_csv_path = Path(output_csv_path)
        output_csv_path.parent.mkdir(parents=True, exist_ok=True)
        self.dataset.to_csv(output_csv_path, index=False, encoding="utf-8")
        return self