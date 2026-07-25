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
    
    def add_tourism_infrastructure(
        self,
        dataset: pd.DataFrame,
        accommodation_xlsx_path: str | Path,
        year: int = 2024,
    ) -> pd.DataFrame:
        """
        Aggiunge al dataset in input 3 colonne relative alla dotazione ricettiva
        turistica del comune (fonte ISTAT - Capacità degli esercizi ricettivi),
        facendo il join sul codice ISTAT del comune.

        Colonne aggiunte:
        - posti_letto_alberghieri_totale
        - posti_letto_extra_alberghieri_totale
        - qualita_offerta_alberghiera_pct
        """
        accommodation_xlsx_path = Path(accommodation_xlsx_path)
        if not accommodation_xlsx_path.exists():
            raise FileNotFoundError(
                f"File capacità ricettiva non trovato: {accommodation_xlsx_path}"
            )

        raw = pd.read_excel(accommodation_xlsx_path, header=None, dtype=str)

        # 1. Trova la riga di misura (quella che contiene "Anno/Year" in colonna A)
        measure_row_idx = None
        for idx in range(min(15, len(raw))):
            first_cell = "" if pd.isna(raw.iat[idx, 0]) else str(raw.iat[idx, 0]).strip().lower()
            if first_cell.startswith("anno"):
                measure_row_idx = idx
                break
        if measure_row_idx is None or measure_row_idx == 0:
            raise ValueError(
                "Impossibile individuare la riga con 'Anno/Year' nel file."
            )

        measure_row = raw.iloc[measure_row_idx]

        # 2. Combina TUTTE le righe sopra la riga di misura (categoria + sottocategoria,
        #    a prescindere da quante righe siano) applicando ffill per colonna, così
        #    da recuperare il testo delle celle unite (che compaiono vuote in pandas
        #    tranne che nella prima colonna del gruppo).
        header_rows = raw.iloc[:measure_row_idx].ffill(axis=1)
        combined_header = header_rows.apply(
            lambda col: " ".join(str(v) for v in col if pd.notna(v)), axis=0
        ).str.lower()

        def _clean(v) -> str:
            return "" if pd.isna(v) else str(v).strip().lower()

        def _find_col(header_keyword: str, measure_keyword: str) -> int:
            candidates = []
            for col in range(raw.shape[1]):
                header_match = header_keyword in combined_header.iat[col]
                measure_match = measure_keyword in _clean(measure_row.iat[col])
                if header_match and measure_match:
                    candidates.append(col)
            if not candidates:
                debug = [
                    (col, combined_header.iat[col], _clean(measure_row.iat[col]))
                    for col in range(raw.shape[1])
                    if "total" in combined_header.iat[col]
                ]
                raise ValueError(
                    f"Colonna non trovata per header contenente '{header_keyword}' "
                    f"e misura contenente '{measure_keyword}'. Colonne con 'total*' trovate: {debug}"
                )
            # prendo la prima corrispondenza da sinistra: nel layout ISTAT il blocco
            # "totale alberghi"/"totale extra-alberghieri" precede sempre l'eventuale
            # colonna "TOTALE/TOTAL" generale che, per via del ffill, eredita lo stesso
            # testo di categoria e potrebbe comparire come falso candidato più a destra.
            return candidates[0]

        col_cod_istat = None
        for col in range(raw.shape[1]):
            if "istat" in _clean(measure_row.iat[col]):
                col_cod_istat = col
                break
        if col_cod_istat is None:
            raise ValueError("Colonna 'Cod. Istat' non trovata nel file.")

        col_anno = 0
        col_letti_alberghi_tot = _find_col("totale alberghi", "letti")
        col_letti_extra_tot = _find_col("totale extra-alberghieri", "letti")
        col_letti_5stelle = _find_col("5 stelle", "letti")
        col_letti_4stelle = _find_col("4 stelle", "letti")

        data = raw.iloc[measure_row_idx + 1 :].reset_index(drop=True)

        def _to_number(v) -> float:
            s = "" if pd.isna(v) else str(v).strip()
            if s in ("", "-", "–", "—"):
                return 0.0
            s = s.replace(".", "").replace(",", ".")
            try:
                return float(s)
            except ValueError:
                return 0.0

        anno = pd.to_numeric(data.iloc[:, col_anno], errors="coerce")
        subset = data[anno == year].copy()
        if subset.empty:
            raise ValueError(f"Nessun dato trovato nel file per l'anno {year}.")

        cod_istat = subset.iloc[:, col_cod_istat].astype(str).str.strip()
        letti_alberghi_tot = subset.iloc[:, col_letti_alberghi_tot].map(_to_number)
        letti_extra_tot = subset.iloc[:, col_letti_extra_tot].map(_to_number)
        letti_5stelle = subset.iloc[:, col_letti_5stelle].map(_to_number)
        letti_4stelle = subset.iloc[:, col_letti_4stelle].map(_to_number)

        quota_alta_gamma = pd.Series(0.0, index=letti_alberghi_tot.index)
        mask_has_hotels = letti_alberghi_tot != 0
        quota_alta_gamma[mask_has_hotels] = (
            (letti_5stelle[mask_has_hotels] + letti_4stelle[mask_has_hotels])
            / letti_alberghi_tot[mask_has_hotels]
            * 100
        ).round(2)

        tourism = pd.DataFrame(
            {
                "_join_key": pd.to_numeric(cod_istat, errors="coerce"),
                "posti_letto_alberghieri_totale": letti_alberghi_tot,
                "posti_letto_extra_alberghieri_totale": letti_extra_tot,
                "qualita_offerta_alberghiera_pct": quota_alta_gamma,
            }
        )

        result = dataset.copy()
        result["_join_key"] = pd.to_numeric(result["cod_istat"], errors="coerce")
        result = result.merge(tourism, on="_join_key", how="left").drop(columns="_join_key")
        return result
    
    def add_population(
        self,
        dataset: pd.DataFrame,
        population_csv_path: str | Path,
    ) -> pd.DataFrame:
        """
        Aggiunge al dataset in input la popolazione residente totale del comune
        (fonte ISTAT - Popolazione residente per età, sesso e stato civile),
        facendo il join sul codice ISTAT del comune.

        Colonna aggiunta:
        - total_population
        """
        population_csv_path = Path(population_csv_path)
        if not population_csv_path.exists():
            raise FileNotFoundError(
                f"CSV popolazione non trovato: {population_csv_path}"
            )

        POP_KEY_FIELD = "Codice comune"
        POP_ETA_FIELD = "Età"
        POP_TOTALE_FIELD = "Totale"
        POP_ETA_TOTALE = 999

        # La prima riga del file è un titolo descrittivo (non l'header delle
        # colonne), quindi la saltiamo con skiprows=1. Tutti i campi sono tra
        # virgolette e separati da ';'.
        pop_df = pd.read_csv(
            population_csv_path,
            sep=";",
            skiprows=1,
            dtype=str,
            encoding="utf-8",
        )

        missing = [
            c for c in (POP_KEY_FIELD, POP_ETA_FIELD, POP_TOTALE_FIELD)
            if c not in pop_df.columns
        ]
        if missing:
            raise ValueError(
                f"Colonne attese non trovate nel CSV popolazione: {missing}. "
                f"Colonne disponibili: {list(pop_df.columns)}"
            )

        # L'età arriva come stringa (es. "999"): la convertiamo per poter
        # filtrare sulla riga di totale.
        eta_numeric = pd.to_numeric(pop_df[POP_ETA_FIELD], errors="coerce")
        totals = pop_df[eta_numeric == POP_ETA_TOTALE].copy()
        if totals.empty:
            raise ValueError(
                f"Nessuna riga con Età = {POP_ETA_TOTALE} trovata nel CSV popolazione."
            )

        def _to_number(v) -> float:
            s = "" if pd.isna(v) else str(v).strip()
            if s in ("", "-", "–", "—"):
                return 0.0
            s = s.replace(".", "").replace(",", ".")
            try:
                return float(s)
            except ValueError:
                return 0.0

        population = pd.DataFrame(
            {
                # Il codice comune è alfanumerico con zero iniziali (es. "028001"):
                # per il join lo normalizziamo a numero, come per gli altri join.
                "_join_key": pd.to_numeric(totals[POP_KEY_FIELD], errors="coerce"),
                "total_population": totals[POP_TOTALE_FIELD].map(_to_number),
            }
        )

        # Se per lo stesso comune ci fossero più righe di totale (non dovrebbe
        # succedere ma per sicurezza), teniamo l'ultima.
        population = population.drop_duplicates(subset="_join_key", keep="last")

        result = dataset.copy()
        result["_join_key"] = pd.to_numeric(result["cod_istat"], errors="coerce")
        result = result.merge(population, on="_join_key", how="left").drop(columns="_join_key")
        return result

    def save_to_csv(self, dataset: pd.DataFrame, output_csv_path: str | Path) -> None:
        output_csv_path = Path(output_csv_path)
        output_csv_path.parent.mkdir(parents=True, exist_ok=True)
        dataset.to_csv(output_csv_path, index=False, encoding="utf-8")