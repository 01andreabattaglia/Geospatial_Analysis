from .utils.othersources_manager import OtherSources

other_sources = OtherSources()
dataset = other_sources.load_municipalities("data/input/Com01012024_g/Com01012024_g_WGS84.shp")
dataset = other_sources.add_UNESCO_sites(dataset, "data/input/other_sources/UNESCO_sites.csv")

other_sources.save_to_csv(dataset, "data/output/other_sources_dataset.csv")