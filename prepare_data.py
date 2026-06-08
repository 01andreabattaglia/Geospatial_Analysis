import os
import sys

# Aggiunge la cartella corrente al path per permettere l'importazione da src
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from src.process_tourism import extract_tourism_data

def main():
    input_excel = "data/2. Dati comunali 2014-2024.xlsx"
    output_csv = "data/presenze_turistiche_2024.csv"
    
    print("Avvio elaborazione dati ISTAT turismo...")
    
    if os.path.exists(input_excel):
        extract_tourism_data(input_excel, output_csv)
    else:
        print(f"Errore: Impossibile trovare il file excel nel percorso: {input_excel}")

if __name__ == "__main__":
    main()
