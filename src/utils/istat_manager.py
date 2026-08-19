from __future__ import annotations

from pathlib import Path

import geopandas as gpd
import pandas as pd

METRIC_CRS = "EPSG:32632"
ISTAT_CODE_FIELD = "PRO_COM"
MUNICIPALITY_NAME_FIELD = "COMUNE"


class ISTAT:
    """Each `add_*` method works on the internal `self.dataset` dataset.

    Typical usage::

        istat = ISTAT()
        istat.load_municipalities(path_shp)
        istat.add_territory_characteristics(path_csv)
        istat.add_tourism_infrastructure(path_xlsx)
        istat.add_population(path_csv)
        istat.save_to_csv(path_csv)

    There is no longer any need to pass/reassign the DataFrame between one
    method and the next: each one reads and updates `self.dataset` in-place
    and returns `self`, so calls can also be chained if desired, but this
    is not mandatory.
    """

    def __init__(self) -> None:
        self.dataset: pd.DataFrame | None = None

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _require_dataset(self, caller_name: str) -> None:
        if self.dataset is None:
            raise RuntimeError(
                f"Dataset not initialized. Call load_municipalities() before {caller_name}()."
            )

    @staticmethod
    def _to_number(v) -> float:
        s = "" if pd.isna(v) else str(v).strip()
        if s in ("", "-", "–", "—"):
            return 0.0
        s = s.replace(".", "").replace(",", ".")
        try:
            return float(s)
        except ValueError:
            return 0.0

    # ------------------------------------------------------------------
    # Base loading
    # ------------------------------------------------------------------

    def load_municipalities(self, municipalities_shp_path: str | Path) -> "ISTAT":
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

        df = pd.DataFrame(gdf[[ISTAT_CODE_FIELD, MUNICIPALITY_NAME_FIELD]])
        self.dataset = df.rename(columns={
            ISTAT_CODE_FIELD: "istat_code",
            MUNICIPALITY_NAME_FIELD: "municipality",
        })
        return self

    # ------------------------------------------------------------------
    # Methods that attach new columns to self.dataset
    # ------------------------------------------------------------------

    def add_territory_characteristics(
        self,
        characteristics_csv_path: str | Path,
    ) -> "ISTAT":
        self._require_dataset("add_territory_characteristics")

        characteristics_csv_path = Path(characteristics_csv_path)
        if not characteristics_csv_path.exists():
            raise FileNotFoundError(
                f"Territory characteristics CSV not found: {characteristics_csv_path}"
            )

        CHARACTERISTICS_KEY_FIELD = "Codice Comune (alfanumerico)"
        CHARACTERISTICS_ISLAND_FIELD = "Comune isolano"
        CHARACTERISTICS_ALTITUDE_ZONE_FIELD = "Zona altimetrica"

        characteristics_df = pd.read_csv(
            characteristics_csv_path,
            sep=";",
            dtype={CHARACTERISTICS_KEY_FIELD: str},
            encoding="utf-8",
        )

        missing = [
            c for c in (CHARACTERISTICS_KEY_FIELD, CHARACTERISTICS_ISLAND_FIELD, CHARACTERISTICS_ALTITUDE_ZONE_FIELD)
            if c not in characteristics_df.columns
        ]
        if missing:
            raise ValueError(
                f"Expected columns not found in the CSV: {missing}. "
                f"Available columns: {list(characteristics_df.columns)}"
            )

        characteristics_lookup = characteristics_df[
            [CHARACTERISTICS_KEY_FIELD, CHARACTERISTICS_ISLAND_FIELD, CHARACTERISTICS_ALTITUDE_ZONE_FIELD]
        ].copy()
        characteristics_lookup["_join_key"] = pd.to_numeric(
            characteristics_lookup[CHARACTERISTICS_KEY_FIELD], errors="coerce"
        )

        result = self.dataset.copy()
        result["_join_key"] = pd.to_numeric(result["istat_code"], errors="coerce")

        result = result.merge(
            characteristics_lookup[["_join_key", CHARACTERISTICS_ISLAND_FIELD, CHARACTERISTICS_ALTITUDE_ZONE_FIELD]],
            on="_join_key",
            how="left",
        ).drop(columns="_join_key")

        result = result.rename(columns={
            CHARACTERISTICS_ISLAND_FIELD: "island_municipality",
            CHARACTERISTICS_ALTITUDE_ZONE_FIELD: "altitude_zone",
        })[["istat_code", "municipality", "island_municipality", "altitude_zone"]]

        self.dataset = result
        return self

    def add_tourism_infrastructure(
        self,
        accommodation_xlsx_path: str | Path,
        year: int = 2024,
    ) -> "ISTAT":
        """
        Adds 2 columns to the dataset related to the municipality's tourist
        accommodation capacity (source: ISTAT - Capacity of accommodation
        establishments), joining on the municipality's ISTAT code.

        Columns added:
        - total_hotel_beds
        - total_non_hotel_beds
        """
        self._require_dataset("add_tourism_infrastructure")

        accommodation_xlsx_path = Path(accommodation_xlsx_path)
        if not accommodation_xlsx_path.exists():
            raise FileNotFoundError(
                f"Accommodation capacity file not found: {accommodation_xlsx_path}"
            )

        raw = pd.read_excel(accommodation_xlsx_path, header=None, dtype=str)

        # 1. Find the measure row (the one containing "Anno/Year" in column A)
        measure_row_idx = None
        for idx in range(min(15, len(raw))):
            first_cell = "" if pd.isna(raw.iat[idx, 0]) else str(raw.iat[idx, 0]).strip().lower()
            if first_cell.startswith("anno"):
                measure_row_idx = idx
                break
        if measure_row_idx is None or measure_row_idx == 0:
            raise ValueError(
                "Unable to locate the row containing 'Anno/Year' in the file."
            )

        measure_row = raw.iloc[measure_row_idx]

        # 2. Combine ALL rows above the measure row (category + subcategory,
        #    regardless of how many rows there are) applying ffill per column,
        #    so as to recover the text of merged cells (which appear empty in
        #    pandas except in the first column of the group).
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
                    f"No column found for header containing '{header_keyword}' "
                    f"and measure containing '{measure_keyword}'. Columns with 'total*' found: {debug}"
                )
            # take the first match from the left: in the ISTAT layout the
            # "total hotels"/"total non-hotel" block always precedes any
            # general "TOTALE/TOTAL" column which, due to ffill, inherits the
            # same category text and could appear as a false candidate further
            # to the right.
            return candidates[0]

        col_istat_code = None
        for col in range(raw.shape[1]):
            if "istat" in _clean(measure_row.iat[col]):
                col_istat_code = col
                break
        if col_istat_code is None:
            raise ValueError("Column 'Cod. Istat' not found in the file.")

        col_year = 0
        col_hotel_beds_total = _find_col("totale alberghi", "letti")
        col_non_hotel_beds_total = _find_col("totale extra-alberghieri", "letti")

        data = raw.iloc[measure_row_idx + 1 :].reset_index(drop=True)

        year_series = pd.to_numeric(data.iloc[:, col_year], errors="coerce")
        subset = data[year_series == year].copy()
        if subset.empty:
            raise ValueError(f"No data found in the file for year {year}.")

        istat_code = subset.iloc[:, col_istat_code].astype(str).str.strip()
        hotel_beds_total = subset.iloc[:, col_hotel_beds_total].map(self._to_number)
        non_hotel_beds_total = subset.iloc[:, col_non_hotel_beds_total].map(self._to_number)

        tourism = pd.DataFrame(
            {
                "_join_key": pd.to_numeric(istat_code, errors="coerce"),
                "total_hotel_beds": hotel_beds_total,
                "total_non_hotel_beds": non_hotel_beds_total,
            }
        )

        result = self.dataset.copy()
        result["_join_key"] = pd.to_numeric(result["istat_code"], errors="coerce")
        result = result.merge(tourism, on="_join_key", how="left").drop(columns="_join_key")

        self.dataset = result
        return self

    def add_population(
        self,
        population_csv_path: str | Path,
    ) -> "ISTAT":
        """
        Adds the municipality's total resident population to the dataset
        (source: ISTAT - Resident population by age, sex and marital status),
        joining on the municipality's ISTAT code.

        Column added:
        - total_population
        """
        self._require_dataset("add_population")

        population_csv_path = Path(population_csv_path)
        if not population_csv_path.exists():
            raise FileNotFoundError(
                f"Population CSV not found: {population_csv_path}"
            )

        POPULATION_KEY_FIELD = "Codice comune"
        POPULATION_AGE_FIELD = "Età"
        POPULATION_TOTAL_FIELD = "Totale"
        POPULATION_AGE_TOTAL_CODE = 999

        # The first row of the file is a descriptive title (not the column
        # header), so we skip it with skiprows=1. All fields are quoted and
        # separated by ';'.
        population_df = pd.read_csv(
            population_csv_path,
            sep=";",
            skiprows=1,
            dtype=str,
            encoding="utf-8",
        )

        missing = [
            c for c in (POPULATION_KEY_FIELD, POPULATION_AGE_FIELD, POPULATION_TOTAL_FIELD)
            if c not in population_df.columns
        ]
        if missing:
            raise ValueError(
                f"Expected columns not found in the population CSV: {missing}. "
                f"Available columns: {list(population_df.columns)}"
            )

        # Age comes in as a string (e.g. "999"): we convert it so we can
        # filter on the total row.
        age_numeric = pd.to_numeric(population_df[POPULATION_AGE_FIELD], errors="coerce")
        totals = population_df[age_numeric == POPULATION_AGE_TOTAL_CODE].copy()
        if totals.empty:
            raise ValueError(
                f"No row with Age = {POPULATION_AGE_TOTAL_CODE} found in the population CSV."
            )

        population = pd.DataFrame(
            {
                # The municipality code is alphanumeric with leading zeros
                # (e.g. "028001"): for the join we normalize it to a number,
                # as with the other joins.
                "_join_key": pd.to_numeric(totals[POPULATION_KEY_FIELD], errors="coerce"),
                "total_population": totals[POPULATION_TOTAL_FIELD].map(self._to_number),
            }
        )

        # If there were multiple total rows for the same municipality
        # (shouldn't happen, but just in case), keep the last one.
        population = population.drop_duplicates(subset="_join_key", keep="last")

        result = self.dataset.copy()
        result["_join_key"] = pd.to_numeric(result["istat_code"], errors="coerce")
        result = result.merge(population, on="_join_key", how="left").drop(columns="_join_key")

        self.dataset = result
        return self

    # ------------------------------------------------------------------
    # Output
    # ------------------------------------------------------------------

    def save_to_csv(self, output_csv_path: str | Path) -> "ISTAT":
        self._require_dataset("save_to_csv")
        output_csv_path = Path(output_csv_path)
        output_csv_path.parent.mkdir(parents=True, exist_ok=True)
        self.dataset.to_csv(output_csv_path, index=False, encoding="utf-8")
        return self