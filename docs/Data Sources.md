# Raw Data Sources

Manual downloads required (not automated by `src/download_data.py`).

| # | Data | Destination | Source |
|---|------|-------------|--------|
| 1 | Municipal characteristics description | `data/input/ISTAT/` | [SITUAS](https://situas.istat.it/web/#/territorio/body?id=73&dateFrom=2024-12-31) |
| 2 | Municipal data 2014-2024 (tourist overnight stays) | `data/input/ISTAT/2. Dati comunali 2014-2024.xlsx` | [IstatData — Tourism, ready-made files](https://esploradati.istat.it/databrowser/#/it/dw/categories/IT1,Z0700SER,1.0/SER_TOURISM) |
| 3 | Accommodation capacity | `data/input/ISTAT/` | [IstatData — Tourism](https://esploradati.istat.it/databrowser/#/it/dw/categories/IT1,Z0700SER,1.0/SER_TOURISM) |
| 4 | Population 2024 | `data/input/ISTAT/` | [ISTAT Demo](https://demo.istat.it/app/?l=it&a=2024&i=POS) |
| 5 | UNESCO World Heritage sites | `data/input/UNESCO/` | [UNESCO Open Data (whc001)](https://data.unesco.org/explore/dataset/whc001/export/) |

Municipal boundaries shapefile (`data/input/ISTAT/Com01012024_g/`) is downloaded automatically — run `python src/download_data.py`.