from dbfread import DBF
import pandas as pd


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