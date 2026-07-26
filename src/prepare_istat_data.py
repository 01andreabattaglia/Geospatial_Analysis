from .utils.istat_manager import ISTAT

def istat_data():
    istat = ISTAT()
    istat.load_municipalities("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp")
    istat.add_territory_characteristics("data/input/ISTAT/Comuni - Caratteristiche del territorio Data Indagine 01-01-2024 Stampa 28062026145352.csv")
    istat.add_tourism_infrastructure("data/input/ISTAT/Capacità comunale 2002-2025.xlsx", year=2024)
    istat.add_population("data/input/ISTAT/POSAS_2024_it_Comuni.csv")

    istat.save_to_csv("data/output/istat_dataset.csv")

if __name__ == "__main__":
    istat_data()