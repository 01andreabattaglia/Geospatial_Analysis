"""
Script per creare una mappa interattiva dei comuni italiani
avviando la funzione delegata posta all'interno della cartella src.
"""

from src.utils.map_generation import generate_map

def main():
    comuni_shapefile = 'data/Limiti01012024_g/Com01012024_g/Com01012024_g_WGS84.shp'
    tourism_csv = 'data/presenze_turistiche_2024.csv'
    output_html = 'mappa_comuni_turismo.html'
    
    generate_map(comuni_shapefile, tourism_csv, output_html)

if __name__ == "__main__":
    main()

