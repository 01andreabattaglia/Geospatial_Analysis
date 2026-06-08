"""
Script per creare una mappa interattiva dei comuni italiani
avviando la funzione delegata posta all'interno della cartella src.
"""

import os
import sys

os.environ['LOKY_MAX_CPU_COUNT'] = '6'  # numero di core logici del tuo PC

# Aggiunge la cartella corrente al path per permettere l'importazione da src
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from src.map_generation import generate_map

def main():
    comuni_shapefile = 'data/Limiti01012024_g/Com01012024_g/Com01012024_g_WGS84.shp'
    tourism_csv = 'data/presenze_turistiche_2024.csv'
    output_html = 'mappa_comuni_turismo.html'
    
    generate_map(comuni_shapefile, tourism_csv, output_html)

if __name__ == "__main__":
    main()

