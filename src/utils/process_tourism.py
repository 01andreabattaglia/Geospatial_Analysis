import pandas as pd



def extract_tourism_data(excel_path, output_csv_path):
    """
    Legge il file excel ISTAT (foglio '2024') ed estrae cod.istat, 
    nome comune e presenze non residenti salvandoli in un CSV.
    """
    print(f"Lettura del file: {excel_path} (potrebbe richiedere qualche secondo)...")
    
    try:
        df = pd.read_excel(excel_path, sheet_name='2024', skiprows=6, header=None)
        
        # In base alla struttura descritta e dai dati estratti:
        # Indice 4: Comune / Municipality
        # Indice 5: Cod. Istat
        # Indice 19: Presenze / Totale esercizi / Non residenti
        
        df_filtered = df[[5, 4, 18]].copy()

        df_filtered.columns = ['cod_istat', 'nome_comune', 'presenze_non_residenti']
        
        df_filtered = df_filtered.dropna(subset=['cod_istat'])

        df_filtered['presenze_non_residenti'] = (
            pd.to_numeric(df_filtered['presenze_non_residenti'], errors='coerce')
            .fillna(0)
            .round(0)
            .astype(int)
        )
        
        df_filtered['cod_istat'] = df_filtered['cod_istat'].apply(
            lambda x: str(int(x)).zfill(6) if pd.notnull(x) and str(x).replace('.','').isdigit() else str(x)
        )
        
        df_filtered.to_csv(output_csv_path, index=False, encoding='utf-8')
        print(f"Completato! Dati salvati con successo in: {output_csv_path}")
        
    except Exception as e:
        print(f"Si è verificato un errore durante l'estrazione: {e}")