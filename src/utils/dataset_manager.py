from dbfread import DBF
import pandas as pd


class DatasetManager:
    """Each `add_*` method works on the internal `self.dataset` dataset.

    Typical usage::

        manager = DatasetManager()
        manager.load_municipalities(path_dbf)
        manager.add_tourism_data(path_xlsx)
        manager.add_extra_features(path_csv)
        manager.save_to_csv(path_csv)

    There is no longer any need to pass/reassign the DataFrame between one
    method and the next: each one reads and updates `self.dataset` in-place
    and returns `self`, so calls can also be chained if desired, but this
    is not mandatory.
    """

    def __init__(self, encoding="utf-8"):
        """
        encoding: useful for handling accented characters in the DBF files
        """
        self.encoding = encoding
        self.dataset: pd.DataFrame | None = None

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _require_dataset(self, caller_name: str) -> None:
        if self.dataset is None:
            raise RuntimeError(
                f"Dataset not initialized. Call load_municipalities() before {caller_name}()."
            )

    # ------------------------------------------------------------------
    # Base loading
    # ------------------------------------------------------------------

    def load_municipalities(self, dbf_path: str) -> "DatasetManager":

        table = DBF(dbf_path, encoding=self.encoding, load=True)
        df = pd.DataFrame(iter(table))

        # normalization
        df.columns = [c.lower() for c in df.columns]

        df["cod_prov"] = df["cod_prov"].astype(str).str.zfill(3)
        df["comune"] = df["comune"].astype(str).str.strip()

        # mapping: DBF field → final name
        rename_map = {
            "cod_prov": "province_code",
            "pro_com_t": "municipality_id",
            "comune": "municipality_name",
        }

        missing = [c for c in rename_map if c not in df.columns]
        if missing:
            raise ValueError(f"Missing columns in the DBF: {missing}")

        result = df.rename(columns=rename_map)[list(rename_map.values())].copy()

        self.dataset = result
        return self

    # ------------------------------------------------------------------
    # Methods that attach new columns to self.dataset
    # ------------------------------------------------------------------

    def add_tourism_data(self, excel_path: str) -> "DatasetManager":
        """
        Reads the ISTAT Excel file (sheet '2024'), extracts the ISTAT code,
        municipality name, and non-resident overnight stays, and performs
        the join with the municipalities dataset on municipality_id / istat_code.
        """
        self._require_dataset("add_tourism_data")

        print(f"Reading file: {excel_path} (this may take a few seconds)...")

        try:
            df = pd.read_excel(excel_path, sheet_name="2024", skiprows=6, header=None)

            # Index 5: Cod. Istat
            # Index 19: Overnight stays / Total establishments / Totals
            df_filtered = df[[5, 19]].copy()
            df_filtered.columns = ["istat_code", "total_overnight_stays"]

            df_filtered = df_filtered.dropna(subset=["istat_code"])

            df_filtered["total_overnight_stays"] = (
                pd.to_numeric(df_filtered["total_overnight_stays"], errors="coerce")
                .fillna(0)
                .round(0)
                .astype(int)
            )

            df_filtered["istat_code"] = df_filtered["istat_code"].apply(
                lambda x: str(int(x)).zfill(6)
                if pd.notnull(x) and str(x).replace(".", "").isdigit()
                else str(x)
            )

        except Exception as e:
            raise ValueError(f"An error occurred while extracting the Excel file: {e}")

        # normalize the join key on the municipalities dataset side
        dataset = self.dataset.copy()
        dataset["municipality_id"] = dataset["municipality_id"].astype(str).str.zfill(6)

        result = dataset.merge(
            df_filtered[["istat_code", "total_overnight_stays"]],
            left_on="municipality_id",
            right_on="istat_code",
            how="left"
        ).drop(columns=["istat_code"])

        result["total_overnight_stays"] = result["total_overnight_stays"].astype("Int64")

        self.dataset = result
        return self

    def add_extra_features(self, csv_path: str) -> "DatasetManager":
        """
        Reads a generic CSV with the format:
        istat_code, municipality_name, <extra columns...>

        Attaches all columns except the first two (istat_code, municipality_name)
        to the existing dataset, performing the join on municipality_id / istat_code.
        """
        self._require_dataset("add_extra_features")

        print(f"Reading file: {csv_path}...")

        try:
            df_extra = pd.read_csv(csv_path)

            if df_extra.shape[1] < 3:
                raise ValueError("The file must contain at least 3 columns (istat_code, municipality_name, + at least one extra column)")

            # first column = join key, second = municipality name (discarded),
            # all remaining columns = columns to attach
            key_col = df_extra.columns[0]
            extra_cols = list(df_extra.columns[2:])

            df_extra = df_extra[[key_col] + extra_cols].copy()
            df_extra = df_extra.rename(columns={key_col: "istat_code"})

            # normalize the join key on the external file side
            df_extra["istat_code"] = (
                df_extra["istat_code"]
                .astype(str)
                .str.extract(r"(\d+)")[0]
                .str.zfill(6)
            )

        except Exception as e:
            raise ValueError(f"An error occurred while reading the CSV file: {e}")

        # normalize the join key on the municipalities dataset side
        dataset = self.dataset.copy()
        dataset["municipality_id"] = dataset["municipality_id"].astype(str).str.zfill(6)

        result = dataset.merge(
            df_extra,
            left_on="municipality_id",
            right_on="istat_code",
            how="left"
        ).drop(columns=["istat_code"])

        self.dataset = result
        return self

    def fill_missing_overnight_stays(self, excel_path: str) -> "DatasetManager":
        """
        Fills missing values (NaN) in 'total_overnight_stays' using the provincial
        aggregate rows present in the ISTAT Excel file (municipality rows whose
        istat_code ends in '777', e.g. "Altri comuni della provincia di TORINO").

        For each province, the aggregate total is distributed among the
        municipalities in the dataset that have a missing total_overnight_stays,
        weighted by their total_population.
        """
        self._require_dataset("fill_missing_overnight_stays")

        if "total_population" not in self.dataset.columns:
            raise RuntimeError(
                "Column 'total_population' is missing: call add_extra_features() "
                "with population data before fill_missing_overnight_stays()."
            )

        print(f"Reading file: {excel_path} (this may take a few seconds)...")

        try:
            df = pd.read_excel(excel_path, sheet_name="2024", skiprows=6, header=None)

            df_filtered = df[[5, 19]].copy()
            df_filtered.columns = ["istat_code", "total_overnight_stays"]
            df_filtered = df_filtered.dropna(subset=["istat_code"])

            df_filtered["istat_code"] = df_filtered["istat_code"].apply(
                lambda x: str(int(x)).zfill(6)
                if pd.notnull(x) and str(x).replace(".", "").isdigit()
                else str(x).strip()
            )

            df_filtered["total_overnight_stays"] = (
                pd.to_numeric(df_filtered["total_overnight_stays"], errors="coerce")
                .fillna(0)
                .round(0)
                .astype(int)
            )

        except Exception as e:
            raise ValueError(f"An error occurred while extracting the Excel file: {e}")

        # keep only the provincial aggregate rows ("Altri comuni della provincia di ...")
        province_rows = df_filtered[df_filtered["istat_code"].str.endswith("777")].copy()
        province_rows["province_code"] = province_rows["istat_code"].str[:3]
        province_totals = province_rows.set_index("province_code")["total_overnight_stays"].to_dict()

        dataset = self.dataset.copy()
        dataset["province_code"] = dataset["province_code"].astype(str).str.zfill(3)

        missing_mask = dataset["total_overnight_stays"].isna()

        for province_code, province_total in province_totals.items():
            prov_missing_mask = missing_mask & (dataset["province_code"] == province_code)

            if not prov_missing_mask.any():
                continue

            population = dataset.loc[prov_missing_mask, "total_population"].fillna(0)
            population_sum = population.sum()

            if population_sum > 0:
                allocation = (population / population_sum) * province_total
            else:
                # no population data available: split equally as a fallback
                allocation = pd.Series(
                    province_total / prov_missing_mask.sum(), index=population.index
                )

            dataset.loc[prov_missing_mask, "total_overnight_stays"] = allocation.round(0).astype(int)

        dataset["total_overnight_stays"] = dataset["total_overnight_stays"].astype("Int64")

        self.dataset = dataset
        return self

    # ------------------------------------------------------------------
    # Output
    # ------------------------------------------------------------------

    def save_to_csv(self, output_path: str, index: bool = False, encoding: str = "utf-8") -> "DatasetManager":
        """
        Saves the dataset to CSV.

        Parameters:
        - output_path: path of the CSV file
        - index: whether to include the index
        - encoding: default utf-8 (recommended)
        """
        self._require_dataset("save_to_csv")

        self.dataset.to_csv(output_path, index=index, encoding=encoding)
        return self