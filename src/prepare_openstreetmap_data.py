from .utils.openstreetmap_manager import OpenStreetMap

if __name__ == "__main__":
    osm = OpenStreetMap()
    osm_dataset = osm.load_municipalities("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp")
    osm_dataset = osm.add_sea_coast_line(osm_dataset, "data/input/OpenStreetMap/coast_line.geojson")
    osm_dataset = osm.add_lake_coast_line(osm_dataset, "data/input/OpenStreetMap/lake_coast.geojson")
    osm_dataset = osm.add_protected_areas(osm_dataset, "data/input/OpenStreetMap/natural_parks.geojson")

    osm.save_to_csv(osm_dataset, "data/output/osm_dataset.csv")