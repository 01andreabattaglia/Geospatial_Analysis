import pandas as pd
import os

def extract_tourism_data(excel_path, output_csv_path):
    """
    Legge il file excel ISTAT (foglio '2024') ed estrae cod.istat, 
    nome comune e presenze totali salvandoli in un CSV.
    """
    print(f"Lettura del file: {excel_path} (potrebbe richiedere qualche secondo)...")
    
    try:
        # Le prime 3 righe sono l'intestazione generale, dalla 4 alla 6 i sub-headers. 
        # I dati iniziano alla riga 7, quindi saltiamo le prime 6 righe (skiprows=6).
        # Leggiamo senza header predefinito per poter selezionare le colonne per indice numerico.
        df = pd.read_excel(excel_path, sheet_name='2024', skiprows=6, header=None)
        
        # In base alla struttura descritta e dai dati estratti:
        # Indice 4: Comune / Municipality
        # Indice 5: Cod. Istat
        # Indice 18: Presenze / Totale esercizi / Totale
        
        # Filtriamo solo le colonne necessarie
        df_filtered = df[[5, 4, 19]].copy()
        
        # Rinominiamo le colonne
        df_filtered.columns = ['cod_istat', 'nome_comune', 'presenze_totali']
        
        # Pulizia base: rimuoviamo eventuali righe vuote dove non c'è il codice istat
        df_filtered = df_filtered.dropna(subset=['cod_istat'])

        # Converti presenze in intero (prima rimuovi separatori migliaia e gestisci NaN)
        df_filtered['presenze_totali'] = (
            pd.to_numeric(df_filtered['presenze_totali'], errors='coerce')
            .fillna(0)
            .round(0)
            .astype(int)
        )
        
        # Gestione del codice ISTAT: assicuriamoci che sia trattato come stringa (6 caratteri con eventuali zeri iniziali)
        df_filtered['cod_istat'] = df_filtered['cod_istat'].apply(
            lambda x: str(int(x)).zfill(6) if pd.notnull(x) and str(x).replace('.','').isdigit() else str(x)
        )
        
        # Salvataggio in CSV
        df_filtered.to_csv(output_csv_path, index=False, encoding='utf-8')
        print(f"Completato! Dati salvati con successo in: {output_csv_path}")
        
    except Exception as e:
        print(f"Si è verificato un errore durante l'estrazione: {e}")

if __name__ == "__main__":
    # Parametri di default se lo script viene eseguito direttamente dalla root
    input_file = "data/2. Dati comunali 2014-2024.xlsx"
    output_file = "data/presenze_turistiche_2024.csv"
    
    if os.path.exists(input_file):
        extract_tourism_data(input_file, output_file)
    else:
        print(f"Errore: Il file {input_file} non esiste in questa posizione, esegui lo script partendo dalla cartella principale.")
