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
BOUNDARY_BUFFER_METERS = 30


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

    def __init__(self) -> None:
        self._comuni_shp_path: Path | None = None

    def load_municipalities(self, comuni_shp_path: str | Path) -> pd.DataFrame:
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

        df = pd.DataFrame(gdf.drop(columns="geometry"))
        return df.select_dtypes(include=["number", "object"])


    def add_sea_coast_line(
        self,
        municipalities: pd.DataFrame,
        coastline_geojson_path: str | Path,
    ) -> pd.DataFrame:
        coastline_geojson_path = Path(coastline_geojson_path)
        if not coastline_geojson_path.exists():
            raise FileNotFoundError(f"GeoJSON linea di costa non trovato: {coastline_geojson_path}")

        if self._comuni_shp_path is None:
            raise ValueError("Shapefile comuni non caricato. Chiama prima load_municipalities().")

        # Ricarica la geometria dallo shapefile per uso interno
        gdf_comuni = gpd.read_file(self._comuni_shp_path)
        comuni = gdf_comuni[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD, "geometry"]].to_crs(METRIC_CRS)

        # Filtra solo i comuni presenti nel DataFrame in input
        comuni = comuni[comuni[COD_ISTAT_FIELD].isin(municipalities[COD_ISTAT_FIELD])]

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
        )

        result = municipalities[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD]].merge(
            coast_per_comune, on=[COD_ISTAT_FIELD, COMUNE_NAME_FIELD], how="left"
        )
        result["km_costa_mare"] = result["km_costa_mare"].fillna(0.0).round(3)

        return result.rename(
            columns={COD_ISTAT_FIELD: "cod_istat", COMUNE_NAME_FIELD: "comune"}
        ).sort_values("cod_istat").reset_index(drop=True)

    def add_lake_coast_line(
        self,
        dataset: pd.DataFrame,
        lake_geojson_path: str | Path,
    ) -> pd.DataFrame:
        """Aggiunge al dataset i chilometri di costa lago per comune.

        Parameters
        ----------
        dataset:
            DataFrame prodotto da :meth:`generate_coast_line`, con almeno
            le colonne ``cod_istat`` e ``comune``.
        lake_geojson_path:
            Percorso al GeoJSON del lago (Polygon/MultiPolygon da OSM/Overpass).

        Returns
        -------
        pd.DataFrame
            Dataset originale con la colonna aggiuntiva ``km_costa_lago``
            (float, arrotondato a 3 decimali; 0.0 per i comuni senza costa lago).
        """
        if self._comuni_shp_path is None:
            raise RuntimeError(
                "Shapefile dei comuni non disponibile. "
                "Chiama load_municipalities() prima di add_lake_coastline()."
            )

        lake_geojson_path = Path(lake_geojson_path)
        if not lake_geojson_path.exists():
            raise FileNotFoundError(f"GeoJSON lago non trovato: {lake_geojson_path}")

        # recupera le geometrie dei comuni dallo shapefile salvato in load_municipalities
        comuni = gpd.read_file(self._comuni_shp_path).to_crs(METRIC_CRS)

        # carica e prepara il perimetro del lago
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

        # buffer sui comuni per catturare tratti sul confine esatto
        comuni_buffered = comuni[[COD_ISTAT_FIELD, "geometry"]].copy()
        comuni_buffered["geometry"] = comuni_buffered.geometry.buffer(BOUNDARY_BUFFER_METERS)

        # intersezione perimetro lago × comuni bufferizzati
        intersection = gpd.overlay(
            lake[["geometry"]],
            comuni_buffered,
            how="intersection",
            keep_geom_type=False,
        )
        intersection["geometry"] = intersection.geometry.apply(_extract_lines)
        intersection = intersection[intersection.geometry.notna()]
        intersection["km_costa_lago"] = (intersection.geometry.length / 1000.0).round(3)

        # aggrega per comune
        coast_per_comune = (
            intersection.groupby(COD_ISTAT_FIELD)["km_costa_lago"]
            .sum()
            .round(3)
            .reset_index()
            .rename(columns={COD_ISTAT_FIELD: "cod_istat"})
        )

        # unisce al dataset originale
        result = dataset.merge(coast_per_comune, on="cod_istat", how="left")
        result["km_costa_lago"] = result["km_costa_lago"].fillna(0.0)

        return result
    
    def add_protected_areas(
        self,
        dataset: pd.DataFrame,
        parks_geojson_path: str | Path,
    ) -> pd.DataFrame:
        """Aggiunge al dataset i chilometri quadrati coperti da aree protette per comune.

        Parameters
        ----------
        dataset:
            DataFrame prodotto da :meth:`generate_coast_line`, con almeno
            le colonne ``cod_istat`` e ``comune``.
        parks_geojson_path:
            Percorso al GeoJSON delle aree naturali protette (Polygon/MultiPolygon
            da OSM/Overpass), es. ``data/input/OpenStreetMap/natural_parks.geojson``.

        Returns
        -------
        pd.DataFrame
            Dataset originale con la colonna aggiuntiva ``kmq_aree_protette``
            (float, arrotondato a 3 decimali; 0.0 per i comuni senza aree protette).
        """
        if self._comuni_shp_path is None:
            raise RuntimeError(
                "Shapefile dei comuni non disponibile. "
                "Chiama load_municipalities() prima di add_protected_areas()."
            )

        parks_geojson_path = Path(parks_geojson_path)
        if not parks_geojson_path.exists():
            raise FileNotFoundError(f"GeoJSON aree protette non trovato: {parks_geojson_path}")

        # recupera le geometrie dei comuni dallo shapefile salvato in load_municipalities
        comuni = gpd.read_file(self._comuni_shp_path).to_crs(METRIC_CRS)

        # carica e prepara le aree protette
        parks = gpd.read_file(parks_geojson_path)
        if parks.crs is None:
            parks = parks.set_crs("EPSG:4326")

        parks = parks[parks.geometry.notna()]
        parks = parks[parks.geom_type.isin(["Polygon", "MultiPolygon"])]
        if parks.empty:
            raise ValueError("Il GeoJSON delle aree protette non contiene geometrie poligonali valide.")

        parks = parks.to_crs(METRIC_CRS)

        # intersezione aree protette × comuni (senza buffer: le superfici devono sovrapporsi)
        intersection = gpd.overlay(
            parks[["geometry"]],
            comuni[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD, "geometry"]],
            how="intersection",
            keep_geom_type=False,
        )
        intersection = intersection[
            intersection.geom_type.isin(["Polygon", "MultiPolygon"])
        ]
        intersection["kmq_aree_protette"] = (intersection.geometry.area / 1_000_000.0).round(3)

        # aggrega per comune
        area_per_comune = (
            intersection.groupby(COD_ISTAT_FIELD)["kmq_aree_protette"]
            .sum()
            .round(3)
            .reset_index()
            .rename(columns={COD_ISTAT_FIELD: "cod_istat"})
        )

        # unisce al dataset originale
        result = dataset.merge(area_per_comune, on="cod_istat", how="left")
        result["kmq_aree_protette"] = result["kmq_aree_protette"].fillna(0.0)

        return result

    def add_museums(
        self,
        dataset: pd.DataFrame,
        museums_geojson_path: str | Path,
    ) -> pd.DataFrame:
        """Aggiunge al dataset il numero di musei per comune.

        Supporta geometrie Point (nodi OSM) e Polygon/MultiPolygon
        (way/relation OSM), in quest'ultimo caso il centroide viene usato
        come punto di riferimento per il join spaziale.

        Parameters
        ----------
        dataset:
            DataFrame con almeno le colonne ``cod_istat`` e ``comune``.
        museums_geojson_path:
            Percorso al GeoJSON dei musei (da OSM/Overpass).

        Returns
        -------
        pd.DataFrame
            Dataset originale con la colonna aggiuntiva ``museums``
            (int, 0 per i comuni senza musei).
        """
        if self._comuni_shp_path is None:
            raise RuntimeError(
                "Shapefile dei comuni non disponibile. "
                "Chiama load_municipalities() prima di add_museums()."
            )

        museums_geojson_path = Path(museums_geojson_path)
        if not museums_geojson_path.exists():
            raise FileNotFoundError(f"GeoJSON musei non trovato: {museums_geojson_path}")

        # carica i confini comunali in CRS metrico
        comuni = gpd.read_file(self._comuni_shp_path).to_crs(METRIC_CRS)

        # carica i musei e normalizza il CRS
        museums = gpd.read_file(museums_geojson_path)
        if museums.crs is None:
            museums = museums.set_crs("EPSG:4326")

        museums = museums[museums.geometry.notna()]

        # separa punti da poligoni (way/relation OSM taggati come museo)
        point_mask = museums.geom_type.isin(["Point", "MultiPoint"])
        poly_mask = museums.geom_type.isin(["Polygon", "MultiPolygon"])

        parts = []
        if point_mask.any():
            parts.append(museums[point_mask][["geometry"]])

        if poly_mask.any():
            # usa il centroide come punto rappresentativo
            poly_as_points = museums[poly_mask][["geometry"]].copy()
            poly_as_points["geometry"] = poly_as_points.geometry.centroid
            parts.append(poly_as_points)

        if not parts:
            raise ValueError(
                "Il GeoJSON dei musei non contiene geometrie valide "
                "(attesi Point, MultiPoint, Polygon o MultiPolygon)."
            )

        museums_points = pd.concat(parts, ignore_index=True)
        museums_gdf = gpd.GeoDataFrame(museums_points, geometry="geometry", crs="EPSG:4326")
        museums_gdf = museums_gdf.to_crs(METRIC_CRS)

        # spatial join: ogni museo → comune che lo contiene
        joined = gpd.sjoin(
            museums_gdf,
            comuni[[COD_ISTAT_FIELD, "geometry"]],
            how="left",
            predicate="within",
        )

        # conta i musei per comune
        museums_per_comune = (
            joined.groupby(COD_ISTAT_FIELD)
            .size()
            .reset_index(name="museums")
            .rename(columns={COD_ISTAT_FIELD: "cod_istat"})
        )
        museums_per_comune["museums"] = museums_per_comune["museums"].astype(int)

        # unisce al dataset originale
        result = dataset.merge(museums_per_comune, on="cod_istat", how="left")
        result["museums"] = result["museums"].fillna(0).astype(int)

        return result
    
    def add_historical_poi(
        self,
        dataset: pd.DataFrame,
        historical_poi_tsv_path: str | Path,
    ) -> pd.DataFrame:
        """Aggiunge al dataset il numero di siti storico-monumentali per comune.
 
        Legge un TSV con colonne ``@id``, ``@lat``, ``@lon``, ``historic``
        (tipicamente esportato da Overpass, es. tag ``historic=monument``,
        ``historic=castle``, ``historic=archaeological_site``, ecc.) e
        conta quanti punti ricadono in ciascun comune tramite join spaziale.
 
        Parameters
        ----------
        dataset:
            DataFrame con almeno le colonne ``cod_istat`` e ``comune``.
        historical_poi_tsv_path:
            Percorso al TSV dei siti storici (da OSM/Overpass), es.
            ``data/input/OpenStreetMap/historical_POI.tsv``.
 
        Returns
        -------
        pd.DataFrame
            Dataset originale con la colonna aggiuntiva ``historical_sites``
            (int, 0 per i comuni senza siti storico-monumentali).
        """
        if self._comuni_shp_path is None:
            raise RuntimeError(
                "Shapefile dei comuni non disponibile. "
                "Chiama load_municipalities() prima di add_historical_poi()."
            )
 
        historical_poi_tsv_path = Path(historical_poi_tsv_path)
        if not historical_poi_tsv_path.exists():
            raise FileNotFoundError(
                f"TSV siti storico-monumentali non trovato: {historical_poi_tsv_path}"
            )
 
        # carica i confini comunali in CRS metrico
        comuni = gpd.read_file(self._comuni_shp_path).to_crs(METRIC_CRS)
 
        # carica il TSV dei siti storici: tutto come stringa per evitare
        # DtypeWarning e per poter validare manualmente ogni riga prima
        # di convertire lat/lon, così eventuali righe disallineate (es.
        # con un campo mancante) vengono scartate invece di far crashare
        # il parsing dei float.
        poi_df = pd.read_csv(
            historical_poi_tsv_path,
            sep="\t",
            dtype="string",
            low_memory=False,
        )
 
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
                f"[add_historical_poi] Attenzione: scartate {n_invalid} righe su "
                f"{n_total} per coordinate non numeriche o disallineate "
                f"(controllare {historical_poi_tsv_path})."
            )
 
        poi_df = poi_df[valid_mask].copy()
        poi_df["@lat"] = lat_numeric[valid_mask]
        poi_df["@lon"] = lon_numeric[valid_mask]
 
        required_cols = {"@lat", "@lon"}
        missing = required_cols - set(poi_df.columns)
        if missing:
            raise ValueError(
                f"Campi attesi non trovati nel TSV: {sorted(missing)}. "
                f"Colonne disponibili: {list(poi_df.columns)}"
            )
 
        if poi_df.empty:
            raise ValueError("Il TSV dei siti storico-monumentali non contiene coordinate valide.")
 
        poi_gdf = gpd.GeoDataFrame(
            poi_df,
            geometry=gpd.points_from_xy(poi_df["@lon"], poi_df["@lat"]),
            crs="EPSG:4326",
        )
        poi_gdf = poi_gdf.to_crs(METRIC_CRS)
 
        # spatial join: ogni sito storico → comune che lo contiene
        joined = gpd.sjoin(
            poi_gdf[["geometry"]],
            comuni[[COD_ISTAT_FIELD, "geometry"]],
            how="left",
            predicate="within",
        )
 
        # conta i siti per comune
        poi_per_comune = (
            joined.groupby(COD_ISTAT_FIELD)
            .size()
            .reset_index(name="historical_sites")
            .rename(columns={COD_ISTAT_FIELD: "cod_istat"})
        )
        poi_per_comune["historical_sites"] = poi_per_comune["historical_sites"].astype(int)
 
        # unisce al dataset originale
        result = dataset.merge(poi_per_comune, on="cod_istat", how="left")
        result["historical_sites"] = result["historical_sites"].fillna(0).astype(int)
 
        return result

    def save_to_csv(self, dataset: pd.DataFrame, output_csv_path: str | Path) -> None:
        output_csv_path = Path(output_csv_path)
        output_csv_path.parent.mkdir(parents=True, exist_ok=True)
        dataset.to_csv(output_csv_path, index=False, encoding="utf-8")