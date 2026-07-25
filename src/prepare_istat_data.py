from .utils.istat_manager import ISTAT

istat = ISTAT()
comuni_df = istat.load_municipalities("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp")
comuni_df = istat.add_territory_characteristics(comuni_df, "data/input/ISTAT/Comuni - Caratteristiche del territorio Data Indagine 01-01-2024 Stampa 28062026145352.csv",)
comuni_df = istat.add_tourism_infrastructure(comuni_df, "data/input/ISTAT/Capacità comunale 2002-2025.xlsx", year=2024)
comuni_df = istat.add_population(comuni_df, "data/input/ISTAT/POSAS_2024_it_Comuni.csv")

istat.save_to_csv(comuni_df, "data/output/istat_dataset.csv")