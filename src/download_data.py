#!/usr/bin/env python3
"""
Scarica i confini amministrativi comunali ISTAT (1 gennaio 2024, versione
generalizzata, WGS84) e li posiziona in data/input/ISTAT/Com01012024_g/.

Fonte ufficiale ISTAT:
https://www.istat.it/it/archivio/222527

Uso:
    python download_istat_confini.py
"""

import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

# --- Configurazione -------------------------------------------------------

ISTAT_ZIP_URL = (
    "https://www.istat.it/storage/cartografia/confini_amministrativi/"
    "generalizzati/2024/Limiti01012024_g.zip"
)

# Cartella dentro lo zip ISTAT che ci interessa
SOURCE_FOLDER_NAME = "Com01012024_g"

# Radice del progetto = cartella padre di src/ (dove si trova questo script).
# Se sposti lo script altrove, aggiorna questa riga di conseguenza.
PROJECT_ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = PROJECT_ROOT / "data" / "cache"
INPUT_DIR = PROJECT_ROOT / "data" / "input" / "ISTAT"

ZIP_CACHE_PATH = CACHE_DIR / "Limiti01012024_g.zip"
EXTRACT_TMP_DIR = CACHE_DIR / "_tmp_extract_Limiti01012024_g"
DEST_DIR = INPUT_DIR / SOURCE_FOLDER_NAME


def download_zip() -> None:
    if ZIP_CACHE_PATH.exists():
        print(f"[cache] Zip già presente: {ZIP_CACHE_PATH}, salto il download.")
        return

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    print(f"[download] {ISTAT_ZIP_URL}")
    req = urllib.request.Request(
        ISTAT_ZIP_URL, headers={"User-Agent": "Mozilla/5.0"}
    )
    with urllib.request.urlopen(req) as response, open(ZIP_CACHE_PATH, "wb") as out:
        shutil.copyfileobj(response, out)
    print(f"[download] Salvato in {ZIP_CACHE_PATH}")


def extract_com_folder() -> None:
    if DEST_DIR.exists() and any(DEST_DIR.iterdir()):
        print(f"[skip] {DEST_DIR} esiste già e non è vuota, non estraggo di nuovo.")
        return

    if EXTRACT_TMP_DIR.exists():
        shutil.rmtree(EXTRACT_TMP_DIR)
    EXTRACT_TMP_DIR.mkdir(parents=True)

    print(f"[extract] Estrazione zip in cartella temporanea...")
    with zipfile.ZipFile(ZIP_CACHE_PATH) as zf:
        zf.extractall(EXTRACT_TMP_DIR)

    # Lo zip ISTAT contiene una sottocartella (es. Limiti01012024_g/) che a
    # sua volta contiene Com01012024_g, ProvCM01012024_g, Reg01012024_g, ecc.
    # Cerchiamo ricorsivamente la cartella che ci interessa.
    matches = [
        p for p in EXTRACT_TMP_DIR.rglob(SOURCE_FOLDER_NAME) if p.is_dir()
    ]
    if not matches:
        sys.exit(
            f"[errore] Cartella '{SOURCE_FOLDER_NAME}' non trovata nello zip. "
            "Controlla che ISTAT non abbia cambiato la struttura dell'archivio."
        )

    source_folder = matches[0]
    INPUT_DIR.mkdir(parents=True, exist_ok=True)
    if DEST_DIR.exists():
        shutil.rmtree(DEST_DIR)
    shutil.copytree(source_folder, DEST_DIR)
    print(f"[extract] Copiato in {DEST_DIR}")

    shutil.rmtree(EXTRACT_TMP_DIR)


def main() -> None:
    download_zip()
    extract_com_folder()
    print("\nFatto. File disponibili in:")
    for f in sorted(DEST_DIR.glob("*")):
        print(f"  - {f.relative_to(PROJECT_ROOT)}")


if __name__ == "__main__":
    main()