from .utils.othersources_manager import OtherSources

def prepare_othersources_data():
    other_sources = OtherSources()
    other_sources.load_municipalities("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp")
    other_sources.add_UNESCO_sites("data/input/other_sources/UNESCO_sites.csv")

    other_sources.save_to_csv("data/output/other_sources_dataset.csv")

if __name__ == "__main__":
    prepare_othersources_data()