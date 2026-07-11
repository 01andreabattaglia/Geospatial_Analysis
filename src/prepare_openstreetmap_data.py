from .utils.openstreetmap_manager import OpenStreetMap

if __name__ == "__main__":
    osm = OpenStreetMap()
    osm_dataset = osm.load_municipalities("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp")
    osm_dataset = osm.add_sea_coast_line(osm_dataset, "data/input/OpenStreetMap/coast_line.geojson")
    osm_dataset = osm.add_lake_coast_line(osm_dataset, "data/input/OpenStreetMap/lake_coast.geojson")
    osm_dataset = osm.add_protected_areas(osm_dataset, "data/input/OpenStreetMap/natural_parks.geojson")
    osm_dataset = osm.add_historical_sites_and_museums(osm_dataset, "data/input/OpenStreetMap/historical_sites_and_museums.tsv")
    osm_dataset = osm.add_architectural_features(osm_dataset, "data/input/OpenStreetMap/architectural_features.tsv")
    osm_dataset = osm.add_sport_facilities(osm_dataset, "data/input/OpenStreetMap/sports_facilities.tsv")
    osm_dataset = osm.add_nature_based(osm_dataset, "data/input/OpenStreetMap/nature_based.tsv")
    osm_dataset = osm.add_theme_parks(osm_dataset, "data/input/OpenStreetMap/theme_parks.tsv")
    osm_dataset = osm.add_nightlife(osm_dataset, "data/input/OpenStreetMap/nightlife.tsv")

    osm.save_to_csv(osm_dataset, "data/output/osm_dataset.csv")