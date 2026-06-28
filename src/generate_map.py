import os
from .utils.map_manager import Map

import os
os.environ.setdefault("LOKY_MAX_CPU_COUNT", "6")

import warnings
warnings.filterwarnings("ignore", category=UserWarning, module="joblib")


def generate_map(shapefile_path: str, tourism_csv_path: str, output_html_path: str) -> None:
    """
    Orchestratore: richiama in sequenza i metodi della classe Map.
    """
    try:
        map_obj = Map()
        map_obj.load_shapefile(shapefile_path)

        if os.path.exists(tourism_csv_path):
            tourism_data = map_obj.load_tourism_data(tourism_csv_path)
            map_obj.merge_tourism_data(tourism_data)
            map_obj.apply_log_scale()
            map_obj.build_thematic_map()
        else:
            print(f"Attenzione: file del turismo '{tourism_csv_path}' non trovato. Creazione mappa standard...")
            map_obj.build_standard_map()

        map_obj.save(output_html_path)

    except FileNotFoundError as e:
        print(f"Errore: {e}")
    except (ImportError, ModuleNotFoundError) as e:
        print("Errore di dipendenze. Assicurati di aver installato: pip install geopandas folium mapclassify")
        print(f"Dettaglio eccezione: {e}")
    except Exception as e:
        print(f"Errore durante l'elaborazione: {e}")


if __name__ == "__main__":
    # Esempio di utilizzo
    comuni_shapefile = 'data/input/Limiti01012024_g/Com01012024_g/Com01012024_g_WGS84.shp'
    tourism_csv = 'data/tourism_final_dataset.csv'
    output_html = 'mappa_comuni_turismo.html'

    generate_map(comuni_shapefile, tourism_csv, output_html)