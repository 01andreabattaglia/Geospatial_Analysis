from dbfread import DBF
import pandas as pd

from .cultural_attractions import (
    ECCEZIONI_COMUNI,
    MACRO_COLS,
    normalize_name,
    load_cultural_attractions_pivot,
)


class DatasetManager:
    def __init__(self, encoding="utf-8"):
        """
        encoding: utile per gestire caratteri accentati nei DBF
        """
        self.encoding = encoding

    def load_comuni(self, dbf_path: str) -> pd.DataFrame:

        table = DBF(dbf_path, encoding=self.encoding, load=True)
        df = pd.DataFrame(iter(table))

        # normalizzazione
        df.columns = [c.lower() for c in df.columns]

        df["cod_prov"] = df["cod_prov"].astype(str).str.zfill(3)
        df["comune"] = df["comune"].astype(str).str.strip()

        # mapping: DBF → nome finale
        rename_map = {
            "cod_prov": "cod_prov",
            "pro_com_t": "id_comune",
            "comune": "nome_comune"
        }

        missing = [c for c in rename_map if c not in df.columns]
        if missing:
            raise ValueError(f"Colonne mancanti nel DBF: {missing}")

        result = df.rename(columns=rename_map)[list(rename_map.values())].copy()

        return result
    
    def add_tourism_data(self, dataset: pd.DataFrame, excel_path: str) -> pd.DataFrame:
        """
        Legge il file Excel ISTAT (foglio '2024'), estrae cod.istat,
        nome comune e presenze non residenti, ed esegue il join
        con il dataset dei comuni su id_comune / cod_istat.
        """
        print(f"Lettura del file: {excel_path} (potrebbe richiedere qualche secondo)...")

        try:
            df = pd.read_excel(excel_path, sheet_name="2024", skiprows=6, header=None)

            # Indice 5: Cod. Istat
            # Indice 19: Presenze / Totale esercizi / Totali
            df_filtered = df[[5, 19]].copy()
            df_filtered.columns = ["cod_istat", "presenze_totali"]

            df_filtered = df_filtered.dropna(subset=["cod_istat"])

            df_filtered["presenze_totali"] = (
                pd.to_numeric(df_filtered["presenze_totali"], errors="coerce")
                .fillna(0)
                .round(0)
                .astype(int)
            )

            df_filtered["cod_istat"] = df_filtered["cod_istat"].apply(
                lambda x: str(int(x)).zfill(6)
                if pd.notnull(x) and str(x).replace(".", "").isdigit()
                else str(x)
            )

        except Exception as e:
            raise ValueError(f"Si è verificato un errore durante l'estrazione del file Excel: {e}")

        # normalizzazione chiave di join lato dataset comuni
        dataset = dataset.copy()
        dataset["id_comune"] = dataset["id_comune"].astype(str).str.zfill(6)

        result = dataset.merge(
            df_filtered[["cod_istat", "presenze_totali"]],
            left_on="id_comune",
            right_on="cod_istat",
            how="left"
        ).drop(columns=["cod_istat"])

        result["presenze_totali"] = result["presenze_totali"].astype("Int64")

        return result
    
    def add_geological_characteristics(self, dataset: pd.DataFrame, csv_path: str, encoding: str = "utf-8") -> pd.DataFrame:
        """
        Legge il file CSV con le caratteristiche dei comuni (ripartizioni ISTAT),
        estrae codice comune, comune isolano, comune litoraneo e zona altimetrica,
        ed esegue il join con il dataset dei comuni su id_comune / Codice Comune (alfanumerico).
        """
        print(f"Lettura del file: {csv_path}...")

        try:
            df = pd.read_csv(csv_path, sep=";", encoding=encoding, dtype=str)
        except Exception as e:
            raise ValueError(f"Si è verificato un errore durante la lettura del file CSV: {e}")

        required_cols = [
            "Codice Comune (alfanumerico)",
            "Comune isolano",
            "Comune litoraneo",
            "Zona altimetrica",
        ]
        missing = [c for c in required_cols if c not in df.columns]
        if missing:
            raise ValueError(f"Colonne mancanti nel CSV: {missing}")

        df_filtered = df[required_cols].copy()
        df_filtered.columns = [
            "cod_comune_alfanumerico",
            "comune_isolano",
            "comune_litoraneo",
            "zona_altimetrica",
        ]

        df_filtered["cod_comune_alfanumerico"] = (
            df_filtered["cod_comune_alfanumerico"].astype(str).str.strip().str.zfill(6)
        )

        # normalizzazione chiave di join lato dataset comuni
        dataset = dataset.copy()
        dataset["id_comune"] = dataset["id_comune"].astype(str).str.zfill(6)

        result = dataset.merge(
            df_filtered,
            left_on="id_comune",
            right_on="cod_comune_alfanumerico",
            how="left"
        ).drop(columns=["cod_comune_alfanumerico"])

        return result
    
    def add_cultural_attractions(self, dataset: pd.DataFrame, csv_path: str) -> pd.DataFrame:
        """
        Legge il file CSV delle attrazioni turistiche, mappa le tipologie
        in macro-categorie ed esegue il join con il dataset dei comuni
        su nome_comune / comune, aggiungendo il conteggio per ciascuna
        macro-categoria. Le tipologie riferite a enti/istituzioni/amministrazione
        vengono escluse.
        """
        print(f"Lettura del file: {csv_path}...")

        try:
            pivot = load_cultural_attractions_pivot(csv_path)

        except Exception as e:
            raise ValueError(
                f"Si è verificato un errore durante "
                f"l'estrazione del file CSV: {e}"
            )

        dataset = dataset.copy()

        dataset["nome_comune"] = (
            dataset["nome_comune"]
            .astype(str)
            .str.strip()
        )

        dataset["_match_key"] = (
            dataset["nome_comune"]
            .apply(normalize_name)
        )

        pivot["_match_key"] = (
            pivot["comune"]
            .apply(normalize_name)
        )

        # applica le eccezioni sui nomi provenienti dal CSV
        pivot["_match_key"] = (
            pivot["_match_key"]
            .replace(ECCEZIONI_COMUNI)
        )

        chiavi_dataset = set(dataset["_match_key"])

        non_trovati = (
            pivot.loc[
                ~pivot["_match_key"].isin(chiavi_dataset),
                "comune",
            ]
            .sort_values()
            .tolist()
        )

        if non_trovati:
            print(
                f"Attenzione: {len(non_trovati)} comuni presenti "
                f"nel file attrazioni ma non trovati nel dataset "
                f"di sinistra (dopo normalizzazione fuzzy): "
                f"{non_trovati}"
            )

        result = (
            dataset.merge(
                pivot.drop(columns=["comune"]),
                on="_match_key",
                how="left",
            )
            .drop(columns=["_match_key"])
        )

        result[MACRO_COLS] = (
            result[MACRO_COLS]
            .fillna(0)
            .astype("Int64")
        )

        return result
        
    def save_to_csv(self, df: pd.DataFrame, output_path: str, index: bool = False, encoding: str = "utf-8") -> None:
        """
        Salva il dataset in CSV.

        Parameters:
        - df: DataFrame da salvare
        - output_path: percorso del file CSV
        - index: se includere l'indice
        - encoding: default utf-8 (consigliato)
        """

        df.to_csv(output_path, index=index, encoding=encoding)