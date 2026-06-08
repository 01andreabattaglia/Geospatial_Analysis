import geopandas as gpd
import pandas as pd
import folium
import numpy as np  # ✅ aggiunto
import os

def generate_map(shapefile_path, tourism_csv_path, output_html_path):
    if not os.path.exists(shapefile_path):
        print(f"Errore: File shapefile non trovato {shapefile_path}")
        return
        
    try:
        print("Caricamento dei dati spaziali dei comuni...")
        comuni = gpd.read_file(shapefile_path)
        
        if os.path.exists(tourism_csv_path):
            print("Caricamento dei dati turistici...")
            tourism_data = pd.read_csv(tourism_csv_path, dtype={'cod_istat': str})
            
            tourism_data['presenze_totali'] = pd.to_numeric(
                tourism_data['presenze_totali']
                    .astype(str)
                    .str.replace('.', '', regex=False)
                    .str.replace('-', '0', regex=False),
                errors='coerce'
            ).fillna(0)

            print("Unione dei dataset (Join)...")
            comuni['PRO_COM_T'] = comuni['PRO_COM_T'].dropna().astype(str).str.zfill(6)
            tourism_data['cod_istat'] = tourism_data['cod_istat'].dropna().astype(str).str.zfill(6)
            
            comuni = comuni.merge(tourism_data, left_on='PRO_COM_T', right_on='cod_istat', how='left')
            comuni['presenze_totali'] = comuni['presenze_totali'].fillna(0)

            # ✅ Scala logaritmica: log1p gestisce i valori 0 senza NaN
            comuni['presenze_log'] = np.log1p(comuni['presenze_totali'])
            
            print("\nCreazione della mappa tematica (scala logaritmica)...")
            k = min(7, comuni['presenze_log'].nunique())
            mappa = comuni.explore(
                column='presenze_log',       # ✅ colonna trasformata
                tooltip=['COMUNE', 'presenze_totali'],  # tooltip mostra i valori originali
                cmap='YlOrRd',
                scheme='NaturalBreaks',
                k=k,
                legend=True,
                tiles='OpenStreetMap',
                zoom_start=6,
                name='Mappa Presenze Turistiche 2024 (log)'
            )
        else:
            print(f"Attenzione: file del turismo '{tourism_csv_path}' non trovato. Creazione mappa standard...")
            mappa = comuni.explore(
                tooltip='COMUNE',
                tiles='OpenStreetMap',
                zoom_start=6,
                name='Comuni'
            )
        
        mappa.add_child(folium.LayerControl())
        mappa.save(output_html_path)
        print(f"\nMappa salvata con successo in: {output_html_path}")
        
    except (ImportError, ModuleNotFoundError) as e:
        print(f"Errore di dipendenze. Assicurati di aver installato: pip install geopandas folium mapclassify")
        print(f"Dettaglio eccezione: {e}")
    except Exception as e:
        print(f"Errore durante l'elaborazione: {e}")