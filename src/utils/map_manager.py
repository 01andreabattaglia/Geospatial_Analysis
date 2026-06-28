import os
import numpy as np
import pandas as pd
import geopandas as gpd
import folium


class Map:
    def __init__(self, cmap: str = "YlOrRd", tiles: str = "OpenStreetMap"):
        """
        cmap: colormap usata per la mappa tematica
        tiles: layer di base per folium/geopandas.explore
        """
        self.cmap = cmap
        self.tiles = tiles
        self.comuni = None
        self.mappa = None

    def load_shapefile(self, shapefile_path: str) -> gpd.GeoDataFrame:
        """
        Carica i dati spaziali dei comuni da shapefile.
        """
        if not os.path.exists(shapefile_path):
            raise FileNotFoundError(f"File shapefile non trovato: {shapefile_path}")

        print("Caricamento dei dati spaziali dei comuni...")
        self.comuni = gpd.read_file(shapefile_path)
        return self.comuni

    def load_tourism_data(self, tourism_csv_path: str) -> pd.DataFrame:
        """
        Legge il CSV turistico e normalizza la colonna presenze_totali
        (gestione valori '-' e NaN).
        """
        print("Caricamento dei dati turistici...")
        tourism_data = pd.read_csv(tourism_csv_path, dtype={"id_comune": str})

        tourism_data["presenze_totali"] = pd.to_numeric(
            tourism_data["presenze_totali"]
                .astype(str)
                .str.replace("-", "0", regex=False),
            errors="coerce"
        ).fillna(0)

        return tourism_data

    def merge_tourism_data(self, tourism_data: pd.DataFrame) -> gpd.GeoDataFrame:
        """
        Esegue il join tra i comuni (self.comuni) e i dati turistici
        su PRO_COM_T / id_comune, normalizzando le chiavi a 6 cifre.
        """
        if self.comuni is None:
            raise ValueError("Nessun dato comuni caricato. Chiama prima load_shapefile().")

        print("Unione dei dataset (Join)...")
        self.comuni["PRO_COM_T"] = self.comuni["PRO_COM_T"].dropna().astype(str).str.zfill(6)
        tourism_data["id_comune"] = tourism_data["id_comune"].dropna().astype(str).str.zfill(6)

        self.comuni = self.comuni.merge(
            tourism_data, left_on="PRO_COM_T", right_on="id_comune", how="left"
        )
        self.comuni["presenze_totali"] = self.comuni["presenze_totali"].fillna(0)

        return self.comuni

    def apply_log_scale(self, column: str = "presenze_totali", new_column: str = "presenze_log") -> gpd.GeoDataFrame:
        """
        Applica una trasformazione log1p alla colonna indicata,
        utile per gestire la scala logaritmica senza generare NaN sugli zeri.
        """
        if self.comuni is None:
            raise ValueError("Nessun dato comuni caricato.")

        self.comuni[new_column] = np.log1p(self.comuni[column])
        return self.comuni

    def build_thematic_map(
        self,
        value_column: str = "presenze_log",
        tooltip: list = None, # type: ignore[arg-type]
        scheme: str = "NaturalBreaks",
        k: int = 7,
        name: str = "Mappa Presenze Turistiche 2024 (log)",
        zoom_start: int = 6,
    ) -> folium.Map:
        """
        Crea la mappa tematica colorata in base a value_column
        (es. presenze_log), con tooltip sui valori originali.
        """
        if self.comuni is None:
            raise ValueError("Nessun dato comuni caricato.")

        tooltip = tooltip or ["COMUNE", "presenze_totali"]
        k = min(k, self.comuni[value_column].nunique())

        print("\nCreazione della mappa tematica (scala logaritmica)...")
        self.mappa = self.comuni.explore(
            column=value_column,
            tooltip=tooltip, # type: ignore[arg-type]
            cmap=self.cmap,
            scheme=scheme,
            k=k,
            legend=True,
            tiles=self.tiles,
            zoom_start=zoom_start,
            name=name,
        )
        return self.mappa

    def build_standard_map(
        self,
        tooltip: str = "COMUNE",
        name: str = "Comuni",
        zoom_start: int = 6,
    ) -> folium.Map:
        """
        Crea una mappa standard (senza dati turistici), usata come fallback
        quando il file CSV del turismo non è disponibile.
        """
        if self.comuni is None:
            raise ValueError("Nessun dato comuni caricato.")

        self.mappa = self.comuni.explore(
            tooltip=tooltip, # type: ignore[arg-type]
            tiles=self.tiles,
            zoom_start=zoom_start,
            name=name,
        )
        return self.mappa

    def save(self, output_html_path: str) -> None:
        """
        Aggiunge il LayerControl e salva la mappa su file HTML.
        """
        if self.mappa is None:
            raise ValueError("Nessuna mappa generata. Chiama prima build_thematic_map() o build_standard_map().")

        self.mappa.add_child(folium.LayerControl())
        self.mappa.save(output_html_path)
        print(f"\nMappa salvata con successo in: {output_html_path}")