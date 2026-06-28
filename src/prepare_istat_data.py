from .utils.istat_manager import ISTAT

istat = ISTAT()
comuni_df = istat.load_municipalities("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp")
comuni_df = istat.add_territory_characteristics(comuni_df, "data/input/ISTAT/Comuni - Caratteristiche del territorio Data Indagine 01-01-2024 Stampa 28062026145352.csv",)
istat.save_to_csv(comuni_df, "data/output/istat_dataset.csv")