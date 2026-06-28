from __future__ import annotations

from pathlib import Path

import geopandas as gpd
import pandas as pd

METRIC_CRS = "EPSG:32632"
COD_ISTAT_FIELD = "PRO_COM"
COMUNE_NAME_FIELD = "COMUNE"


class ISTAT:

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

        df = pd.DataFrame(gdf[[COD_ISTAT_FIELD, COMUNE_NAME_FIELD]])
        return df.rename(columns={
            COD_ISTAT_FIELD: "cod_istat",
            COMUNE_NAME_FIELD: "comune",
        })

    def add_territory_characteristics(
        self,
        municipalities: pd.DataFrame,
        characteristics_csv_path: str | Path,
    ) -> pd.DataFrame:
        characteristics_csv_path = Path(characteristics_csv_path)
        if not characteristics_csv_path.exists():
            raise FileNotFoundError(
                f"CSV caratteristiche territorio non trovato: {characteristics_csv_path}"
            )

        CHAR_KEY_FIELD = "Codice Comune (alfanumerico)"
        CHAR_ISOLANO_FIELD = "Comune isolano"
        CHAR_ZONA_ALT_FIELD = "Zona altimetrica"

        istat_df = pd.read_csv(
            characteristics_csv_path,
            sep=";",
            dtype={CHAR_KEY_FIELD: str},
            encoding="utf-8",
        )

        missing = [
            c for c in (CHAR_KEY_FIELD, CHAR_ISOLANO_FIELD, CHAR_ZONA_ALT_FIELD)
            if c not in istat_df.columns
        ]
        if missing:
            raise ValueError(
                f"Colonne attese non trovate nel CSV: {missing}. "
                f"Colonne disponibili: {list(istat_df.columns)}"
            )

        istat_lookup = istat_df[[CHAR_KEY_FIELD, CHAR_ISOLANO_FIELD, CHAR_ZONA_ALT_FIELD]].copy()
        istat_lookup["_join_key"] = pd.to_numeric(istat_lookup[CHAR_KEY_FIELD], errors="coerce")

        result = municipalities.copy()
        result["_join_key"] = pd.to_numeric(result["cod_istat"], errors="coerce")

        result = result.merge(
            istat_lookup[["_join_key", CHAR_ISOLANO_FIELD, CHAR_ZONA_ALT_FIELD]],
            on="_join_key",
            how="left",
        ).drop(columns="_join_key")

        return result.rename(columns={
            CHAR_ISOLANO_FIELD: "comune_isolano",
            CHAR_ZONA_ALT_FIELD: "zona_altimetrica",
        })[["cod_istat", "comune", "comune_isolano", "zona_altimetrica"]]

    def save_to_csv(self, dataset: pd.DataFrame, output_csv_path: str | Path) -> None:
        output_csv_path = Path(output_csv_path)
        output_csv_path.parent.mkdir(parents=True, exist_ok=True)
        dataset.to_csv(output_csv_path, index=False, encoding="utf-8")