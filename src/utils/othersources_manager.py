from __future__ import annotations

from pathlib import Path

import geopandas as gpd
import pandas as pd
from shapely.geometry import Point

METRIC_CRS = "EPSG:32632"
COD_ISTAT_FIELD = "PRO_COM"
COMUNE_NAME_FIELD = "COMUNE"
COORDINATES_FIELD = "Coordinates"
UNESCO_NAME_FIELD = "Name EN"


def _parse_coordinates(coord_str) -> tuple[float, float] | None:
    """Converte una stringa 'lat, lon' nel dataset UNESCO in una tupla (lat, lon)."""
    if coord_str is None or (isinstance(coord_str, float) and pd.isna(coord_str)):
        return None
    try:
        lat_str, lon_str = str(coord_str).split(",")
        return float(lat_str.strip()), float(lon_str.strip())
    except (ValueError, AttributeError):
        return None


class OtherSources:

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

    def add_UNESCO_sites(
        self,
        municipalities: pd.DataFrame,
        unesco_csv_path: str | Path,
    ) -> pd.DataFrame:
        unesco_csv_path = Path(unesco_csv_path)
        if not unesco_csv_path.exists():
            raise FileNotFoundError(f"CSV siti UNESCO non trovato: {unesco_csv_path}")

        if self._comuni_shp_path is None:
            raise ValueError("Shapefile comuni non caricato. Chiama prima load_municipalities().")

        # Ricarica la geometria dallo shapefile per uso interno
        gdf_comuni = gpd.read_file(self._comuni_shp_path)
        comuni = gdf_comuni[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD, "geometry"]].to_crs(METRIC_CRS)

        # Filtra solo i comuni presenti nel DataFrame in input
        comuni = comuni[comuni[COD_ISTAT_FIELD].isin(municipalities[COD_ISTAT_FIELD])]

        unesco = pd.read_csv(unesco_csv_path)

        if COORDINATES_FIELD not in unesco.columns:
            raise ValueError(
                f"Campo '{COORDINATES_FIELD}' non trovato nel CSV UNESCO. "
                f"Colonne disponibili: {list(unesco.columns)}"
            )

        name_field = UNESCO_NAME_FIELD if UNESCO_NAME_FIELD in unesco.columns else unesco.columns[0]

        parsed_coords = unesco[COORDINATES_FIELD].apply(_parse_coordinates)
        unesco = unesco[parsed_coords.notna()].copy()
        parsed_coords = parsed_coords[parsed_coords.notna()]

        lat = parsed_coords.apply(lambda t: t[0])
        lon = parsed_coords.apply(lambda t: t[1])

        gdf_unesco = gpd.GeoDataFrame(
            unesco[[name_field]].rename(columns={name_field: "nome_sito_unesco"}),
            geometry=[Point(x, y) for x, y in zip(lon, lat)],
            crs="EPSG:4326",
        )
        gdf_unesco = gdf_unesco.to_crs(METRIC_CRS)

        # Left join spaziale: punti UNESCO che ricadono nei confini dei comuni
        joined = gpd.sjoin(
            gdf_unesco,
            comuni[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD, "geometry"]],
            how="inner",
            predicate="within",
        )

        # Il conteggio va calcolato PRIMA di trasformare i nomi in un'unica stringa:
        # alcuni nomi di siti UNESCO contengono virgole al loro interno
        # (es. "Cathedral, Torre Civica and Piazza Grande, Modena" e' UN solo sito),
        # quindi non si puo' ricavare il conteggio ri-splittando la stringa unita.
        sites_per_comune = (
            joined.groupby([COD_ISTAT_FIELD, COMUNE_NAME_FIELD])
            .agg(
                siti_unesco=(
                    "nome_sito_unesco",
                    lambda names: "; ".join(sorted(set(names))),
                ),
                n_siti_unesco=("nome_sito_unesco", "nunique"),
            )
            .reset_index()
        )

        result = municipalities[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD]].merge(
            sites_per_comune, on=[COD_ISTAT_FIELD, COMUNE_NAME_FIELD], how="left"
        )
        result["siti_unesco"] = result["siti_unesco"].fillna("")
        result["n_siti_unesco"] = result["n_siti_unesco"].fillna(0).astype(int)

        return result.rename(
            columns={COD_ISTAT_FIELD: "cod_istat", COMUNE_NAME_FIELD: "comune"}
        ).sort_values("cod_istat").reset_index(drop=True)
    
    def save_to_csv(self, dataset: pd.DataFrame, output_csv_path: str | Path) -> None:
        output_csv_path = Path(output_csv_path)
        output_csv_path.parent.mkdir(parents=True, exist_ok=True)
        dataset.to_csv(output_csv_path, index=False, encoding="utf-8")