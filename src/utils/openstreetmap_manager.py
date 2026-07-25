from __future__ import annotations

import unicodedata
from pathlib import Path

import geopandas as gpd
import pandas as pd
from shapely.geometry import GeometryCollection, LineString, MultiLineString
from shapely.ops import linemerge

METRIC_CRS = "EPSG:32632"
COD_ISTAT_FIELD = "PRO_COM"
COMUNE_NAME_FIELD = "COMUNE"
BOUNDARY_BUFFER_METERS = 20


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
    """Ogni metodo `add_*` lavora sul dataset interno `self.dataset`.

    Uso tipico::

        osm = OpenStreetMap()
        osm.load_municipalities(path_shp)
        osm.add_sea_coast_line(path_geojson)
        osm.add_lake_coast_line(path_geojson)
        ...
        osm.save_to_csv(path_csv)

    Non è più necessario passare/riassegnare il DataFrame tra un metodo e
    l'altro: ognuno legge e aggiorna `self.dataset` in-place e ritorna
    `self`, così le chiamate possono anche essere concatenate (chaining)
    se lo si desidera, ma non è obbligatorio.
    """

    def __init__(self) -> None:
        self._comuni_shp_path: Path | None = None
        self.dataset: pd.DataFrame | None = None

    # ------------------------------------------------------------------
    # Helpers interni
    # ------------------------------------------------------------------

    def _require_dataset(self, caller_name: str) -> None:
        if self.dataset is None or self._comuni_shp_path is None:
            raise RuntimeError(
                f"Dataset non inizializzato. Chiama load_municipalities() prima di {caller_name}()."
            )

    def _merge_column(
        self,
        new_col_df: pd.DataFrame,
        col: str,
        fill_value=0,
        round_ndigits: int | None = None,
        as_int: bool = False,
    ) -> None:
        """Aggancia una nuova colonna (indicizzata per cod_istat) a self.dataset."""
        self.dataset = self.dataset.merge(
            new_col_df[["cod_istat", col]], on="cod_istat", how="left"
        )
        self.dataset[col] = self.dataset[col].fillna(fill_value)
        if round_ndigits is not None:
            self.dataset[col] = self.dataset[col].round(round_ndigits)
        if as_int:
            self.dataset[col] = self.dataset[col].astype(int)

    def _load_comuni_metric(self) -> gpd.GeoDataFrame:
        return gpd.read_file(self._comuni_shp_path).to_crs(METRIC_CRS)

    # ------------------------------------------------------------------
    # Caricamento base
    # ------------------------------------------------------------------

    def load_municipalities(self, comuni_shp_path: str | Path) -> "OpenStreetMap":
        comuni_shp_path = Path(comuni_shp_path)
        if not comuni_shp_path.exists():
            raise FileNotFoundError(f"Shapefile comuni non trovato: {comuni_shp_path}")

        gdf = gpd.read_file(comuni_shp_path)

        missing = [c for c in (COD_ISTAT_FIELD, COMUNE_NAME_FIELD) if c not in gdf.columns]
        if missing:
            raise ValueError(
                f"Campi attesi non trovati nello shapefile: {missing}. "
                f"Colonne disponibili: {list(gdf.columns)}"
            )

        if gdf.crs is None:
            raise ValueError("Lo shapefile non ha un CRS definito (controlla il file .prj).")

        self._comuni_shp_path = comuni_shp_path

        df = pd.DataFrame(gdf.drop(columns="geometry")).select_dtypes(include=["number", "object"])

        self.dataset = (
            df[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD]]
            .rename(columns={COD_ISTAT_FIELD: "cod_istat", COMUNE_NAME_FIELD: "comune"})
            .sort_values("cod_istat")
            .reset_index(drop=True)
        )
        return self

    # ------------------------------------------------------------------
    # Metodi che agganciano nuove colonne a self.dataset
    # ------------------------------------------------------------------

    def add_sea_coast_line(self, coastline_geojson_path: str | Path) -> "OpenStreetMap":
        self._require_dataset("add_sea_coast_line")

        coastline_geojson_path = Path(coastline_geojson_path)
        if not coastline_geojson_path.exists():
            raise FileNotFoundError(f"GeoJSON linea di costa non trovato: {coastline_geojson_path}")

        gdf_comuni = gpd.read_file(self._comuni_shp_path)
        comuni = gdf_comuni[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD, "geometry"]].to_crs(METRIC_CRS)
        comuni = comuni[comuni[COD_ISTAT_FIELD].isin(self.dataset["cod_istat"])]

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

        comuni_lookup = comuni[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD]].copy()
        comuni_lookup["_name_key"] = comuni_lookup[COMUNE_NAME_FIELD].apply(_normalize_name)

        tagged_rows = []
        for _, row in coastline_tagged.iterrows():
            length_km = row.geometry.length / 1000.0
            for side in ("city:left", "city:right"):
                city_name = row[side]
                if city_name is None or (isinstance(city_name, float) and pd.isna(city_name)):
                    continue
                tagged_rows.append({"_name_key": _normalize_name(city_name), "km_costa_mare": length_km})

        coast_from_tags = pd.DataFrame(tagged_rows, columns=["_name_key", "km_costa_mare"])
        coast_from_tags = coast_from_tags.groupby("_name_key", as_index=False)["km_costa_mare"].sum()

        coast_from_overlay = pd.DataFrame(columns=[COD_ISTAT_FIELD, COMUNE_NAME_FIELD, "km_costa_mare"])
        if len(coastline_untagged) > 0:
            comuni_buffered = comuni.copy()
            comuni_buffered["geometry"] = comuni_buffered.geometry.buffer(BOUNDARY_BUFFER_METERS)

            intersection = gpd.overlay(
                coastline_untagged[["geometry"]],
                comuni_buffered[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD, "geometry"]],
                how="intersection",
                keep_geom_type=False,
            )
            intersection["geometry"] = intersection.geometry.apply(_extract_lines)
            intersection = intersection[intersection.geometry.notna()]
            intersection["km_costa_mare"] = intersection.geometry.length / 1000.0

            coast_from_overlay = (
                intersection.groupby([COD_ISTAT_FIELD, COMUNE_NAME_FIELD])["km_costa_mare"]
                .sum()
                .reset_index()
            )

        coast_tagged_by_comune = comuni_lookup.merge(coast_from_tags, on="_name_key", how="inner")
        coast_tagged_by_comune = coast_tagged_by_comune[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD, "km_costa_mare"]]

        coast_combined = pd.concat([coast_tagged_by_comune, coast_from_overlay], ignore_index=True)
        coast_per_comune = (
            coast_combined.groupby([COD_ISTAT_FIELD, COMUNE_NAME_FIELD])["km_costa_mare"]
            .sum()
            .reset_index()
            .rename(columns={COD_ISTAT_FIELD: "cod_istat"})
        )

        self._merge_column(coast_per_comune, "km_costa_mare", fill_value=0.0, round_ndigits=3)
        return self

    def add_lake_coast_line(self, lake_geojson_path: str | Path) -> "OpenStreetMap":
        self._require_dataset("add_lake_coast_line")

        lake_geojson_path = Path(lake_geojson_path)
        if not lake_geojson_path.exists():
            raise FileNotFoundError(f"GeoJSON lago non trovato: {lake_geojson_path}")

        comuni = self._load_comuni_metric()

        lake = gpd.read_file(lake_geojson_path)
        if lake.crs is None:
            lake = lake.set_crs("EPSG:4326")

        lake = lake[lake.geometry.notna()]
        lake = lake[lake.geom_type.isin(["Polygon", "MultiPolygon", "LineString", "MultiLineString"])]
        if lake.empty:
            raise ValueError("Il GeoJSON del lago non contiene geometrie valide.")

        lake = lake.to_crs(METRIC_CRS)
        lake["geometry"] = lake.geometry.apply(
            lambda geom: geom.boundary if geom.geom_type in ("Polygon", "MultiPolygon") else geom
        )

        comuni_buffered = comuni[[COD_ISTAT_FIELD, "geometry"]].copy()
        comuni_buffered["geometry"] = comuni_buffered.geometry.buffer(BOUNDARY_BUFFER_METERS)

        intersection = gpd.overlay(
            lake[["geometry"]],
            comuni_buffered,
            how="intersection",
            keep_geom_type=False,
        )
        intersection["geometry"] = intersection.geometry.apply(_extract_lines)
        intersection = intersection[intersection.geometry.notna()]
        intersection["km_costa_lago"] = (intersection.geometry.length / 1000.0).round(3)

        coast_per_comune = (
            intersection.groupby(COD_ISTAT_FIELD)["km_costa_lago"]
            .sum()
            .round(3)
            .reset_index()
            .rename(columns={COD_ISTAT_FIELD: "cod_istat"})
        )

        self._merge_column(coast_per_comune, "km_costa_lago", fill_value=0.0, round_ndigits=3)
        return self

    def add_protected_areas(self, parks_geojson_path: str | Path) -> "OpenStreetMap":
        self._require_dataset("add_protected_areas")

        parks_geojson_path = Path(parks_geojson_path)
        if not parks_geojson_path.exists():
            raise FileNotFoundError(f"GeoJSON aree protette non trovato: {parks_geojson_path}")

        comuni = self._load_comuni_metric()

        parks = gpd.read_file(parks_geojson_path)
        if parks.crs is None:
            parks = parks.set_crs("EPSG:4326")

        parks = parks[parks.geometry.notna()]
        parks = parks[parks.geom_type.isin(["Polygon", "MultiPolygon"])]
        if parks.empty:
            raise ValueError("Il GeoJSON delle aree protette non contiene geometrie poligonali valide.")

        parks = parks.to_crs(METRIC_CRS)

        intersection = gpd.overlay(
            parks[["geometry"]],
            comuni[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD, "geometry"]],
            how="intersection",
            keep_geom_type=False,
        )
        intersection = intersection[intersection.geom_type.isin(["Polygon", "MultiPolygon"])]
        intersection["kmq_aree_protette"] = (intersection.geometry.area / 1_000_000.0).round(3)

        area_per_comune = (
            intersection.groupby(COD_ISTAT_FIELD)["kmq_aree_protette"]
            .sum()
            .round(3)
            .reset_index()
            .rename(columns={COD_ISTAT_FIELD: "cod_istat"})
        )

        self._merge_column(area_per_comune, "kmq_aree_protette", fill_value=0.0, round_ndigits=3)
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
        """Factory comune a tutti i metodi 'conta punti OSM per comune'."""
        self._require_dataset(caller_name)

        tsv_path = Path(tsv_path)
        if not tsv_path.exists():
            raise FileNotFoundError(f"TSV non trovato: {tsv_path}")

        comuni = self._load_comuni_metric()

        df = pd.read_csv(tsv_path, sep="\t", dtype={"@id": str})

        required_cols = {"@lat", "@lon"}
        missing_cols = required_cols - set(df.columns)
        if missing_cols:
            raise ValueError(f"Colonne mancanti nel TSV: {sorted(missing_cols)}")

        if filter_fn is not None:
            df = filter_fn(df)

        df = df.dropna(subset=["@lat", "@lon"])
        df["@lat"] = pd.to_numeric(df["@lat"], errors="coerce")
        df["@lon"] = pd.to_numeric(df["@lon"], errors="coerce")
        df = df.dropna(subset=["@lat", "@lon"])

        if df.empty:
            raise ValueError(require_message or "Il TSV non contiene record validi con coordinate valide.")

        geometry = gpd.points_from_xy(df["@lon"], df["@lat"])
        keep_cols = [c for c in keep_cols_candidates if c in df.columns] or ["@id"]
        gdf = gpd.GeoDataFrame(df[keep_cols], geometry=geometry, crs="EPSG:4326").to_crs(METRIC_CRS)

        joined = gpd.sjoin(
            gdf, comuni[[COD_ISTAT_FIELD, "geometry"]], how="left", predicate="within"
        )

        counts = (
            joined.groupby(COD_ISTAT_FIELD)
            .size()
            .reset_index(name=col_name)
            .rename(columns={COD_ISTAT_FIELD: "cod_istat"})
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
                "Il TSV dei musei non contiene record validi con "
                "tourism == 'museum' e coordinate valide."
            ),
        )
        return self

    def add_architectural_features(self, architectural_poi_tsv_path: str | Path) -> "OpenStreetMap":
        # Gestione dedicata per righe disallineate: legge tutto come stringa
        # e valida manualmente lat/lon prima di convertirle, così eventuali
        # righe corrotte vengono scartate senza far crashare il parsing.
        self._require_dataset("add_architectural_features")

        architectural_poi_tsv_path = Path(architectural_poi_tsv_path)
        if not architectural_poi_tsv_path.exists():
            raise FileNotFoundError(
                f"TSV siti architettonici non trovato: {architectural_poi_tsv_path}"
            )

        comuni = self._load_comuni_metric()

        poi_df = pd.read_csv(architectural_poi_tsv_path, sep="\t", dtype="string", low_memory=False)

        required_cols = {"@lat", "@lon"}
        missing = required_cols - set(poi_df.columns)
        if missing:
            raise ValueError(
                f"Campi attesi non trovati nel TSV: {sorted(missing)}. "
                f"Colonne disponibili: {list(poi_df.columns)}"
            )

        n_total = len(poi_df)
        lat_numeric = pd.to_numeric(poi_df["@lat"], errors="coerce")
        lon_numeric = pd.to_numeric(poi_df["@lon"], errors="coerce")
        valid_mask = lat_numeric.notna() & lon_numeric.notna()

        n_invalid = n_total - valid_mask.sum()
        if n_invalid > 0:
            print(
                f"[add_architectural_features] Attenzione: scartate {n_invalid} righe su "
                f"{n_total} per coordinate non numeriche o disallineate "
                f"(controllare {architectural_poi_tsv_path})."
            )

        poi_df = poi_df[valid_mask].copy()
        poi_df["@lat"] = lat_numeric[valid_mask]
        poi_df["@lon"] = lon_numeric[valid_mask]

        if poi_df.empty:
            raise ValueError("Il TSV dei siti architettonici non contiene coordinate valide.")

        poi_gdf = gpd.GeoDataFrame(
            poi_df, geometry=gpd.points_from_xy(poi_df["@lon"], poi_df["@lat"]), crs="EPSG:4326"
        ).to_crs(METRIC_CRS)

        joined = gpd.sjoin(
            poi_gdf[["geometry"]],
            comuni[[COD_ISTAT_FIELD, "geometry"]],
            how="left",
            predicate="within",
        )

        poi_per_comune = (
            joined.groupby(COD_ISTAT_FIELD)
            .size()
            .reset_index(name="architectural_features")
            .rename(columns={COD_ISTAT_FIELD: "cod_istat"})
        )
        poi_per_comune["architectural_features"] = poi_per_comune["architectural_features"].astype(int)

        self._merge_column(poi_per_comune, "architectural_features", fill_value=0, as_int=True)
        return self

    def add_sport_facilities(self, sport_facilities_tsv_path: str | Path) -> "OpenStreetMap":
        self._add_point_based_count(
            sport_facilities_tsv_path,
            col_name="sports_facilities",
            caller_name="add_sport_facilities",
            keep_cols_candidates=["@id", "name"],
            require_message=(
                "Il TSV degli impianti sportivi non contiene record validi con coordinate valide."
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
                "Il TSV delle strutture nature-based non contiene record validi con coordinate valide."
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
            require_message="Il TSV dei parchi tematici non contiene record validi con coordinate valide.",
        )
        return self

    def add_nightlife(self, nightlife_tsv_path: str | Path) -> "OpenStreetMap":
        self._add_point_based_count(
            nightlife_tsv_path,
            col_name="nightlife",
            caller_name="add_nightlife",
            keep_cols_candidates=["@id", "amenity", "name"],
            require_message=(
                "Il TSV dei locali per la vita notturna non contiene record validi con coordinate valide."
            ),
        )
        return self

    def add_public_transport_points(self, public_transport_tsv_path: str | Path) -> "OpenStreetMap":
        """Somma i punti di trasporto pubblico alla colonna cumulativa.

        Pensato per essere chiamato più volte in sequenza (es. una volta per
        Nord/Centro/Sud): ogni chiamata legge UN SOLO TSV e SOMMA il
        conteggio alla colonna ``public_transport_points`` già presente in
        ``self.dataset``, senza azzerare i conteggi precedenti.
        """
        self._require_dataset("add_public_transport_points")

        public_transport_tsv_path = Path(public_transport_tsv_path)
        if not public_transport_tsv_path.exists():
            raise FileNotFoundError(
                f"TSV punti di trasporto pubblico non trovato: {public_transport_tsv_path}"
            )

        comuni = self._load_comuni_metric()

        transport_df = pd.read_csv(public_transport_tsv_path, sep="\t", dtype={"@id": str})

        required_cols = {"@lat", "@lon"}
        missing_cols = required_cols - set(transport_df.columns)
        if missing_cols:
            raise ValueError(f"Colonne mancanti nel TSV trasporto pubblico: {sorted(missing_cols)}")

        transport_df = transport_df.dropna(subset=["@lat", "@lon"])
        transport_df["@lat"] = pd.to_numeric(transport_df["@lat"], errors="coerce")
        transport_df["@lon"] = pd.to_numeric(transport_df["@lon"], errors="coerce")
        transport_df = transport_df.dropna(subset=["@lat", "@lon"])

        if transport_df.empty:
            raise ValueError(
                "Il TSV dei punti di trasporto pubblico non contiene record validi con coordinate valide."
            )

        geometry = gpd.points_from_xy(transport_df["@lon"], transport_df["@lat"])
        keep_cols = [c for c in ["@id", "name"] if c in transport_df.columns] or ["@id"]
        transport_gdf = gpd.GeoDataFrame(
            transport_df[keep_cols], geometry=geometry, crs="EPSG:4326"
        ).to_crs(METRIC_CRS)

        joined = gpd.sjoin(
            transport_gdf, comuni[[COD_ISTAT_FIELD, "geometry"]], how="left", predicate="within"
        )

        points_per_comune = (
            joined.groupby(COD_ISTAT_FIELD)
            .size()
            .reset_index(name="new_public_transport_points")
            .rename(columns={COD_ISTAT_FIELD: "cod_istat"})
        )
        points_per_comune["new_public_transport_points"] = points_per_comune[
            "new_public_transport_points"
        ].astype(int)

        if "public_transport_points" not in self.dataset.columns:
            self.dataset["public_transport_points"] = 0

        self.dataset = self.dataset.merge(points_per_comune, on="cod_istat", how="left")
        self.dataset["new_public_transport_points"] = (
            self.dataset["new_public_transport_points"].fillna(0).astype(int)
        )
        self.dataset["public_transport_points"] = (
            self.dataset["public_transport_points"] + self.dataset["new_public_transport_points"]
        ).astype(int)
        self.dataset = self.dataset.drop(columns=["new_public_transport_points"])
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