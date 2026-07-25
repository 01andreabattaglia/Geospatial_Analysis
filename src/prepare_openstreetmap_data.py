from .utils.openstreetmap_manager import OpenStreetMap

if __name__ == "__main__":
    osm = OpenStreetMap()
    osm.load_municipalities("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp")
    osm.add_sea_coast_line("data/input/OpenStreetMap/coast_line.geojson")
    osm.add_lake_coast_line("data/input/OpenStreetMap/lake_coast.geojson")
    osm.add_protected_areas("data/input/OpenStreetMap/natural_parks.geojson")
    osm.add_historical_sites_and_museums("data/input/OpenStreetMap/historical_sites_and_museums.tsv")
    osm.add_architectural_features("data/input/OpenStreetMap/architectural_features.tsv")
    osm.add_sport_facilities("data/input/OpenStreetMap/sports_facilities.tsv")
    osm.add_nature_based("data/input/OpenStreetMap/nature_based.tsv")
    osm.add_theme_parks("data/input/OpenStreetMap/theme_parks.tsv")
    osm.add_nightlife("data/input/OpenStreetMap/nightlife.tsv")
    osm.add_public_transport_points("data/input/OpenStreetMap/public_transport_north_italy.tsv")
    osm.add_public_transport_points("data/input/OpenStreetMap/public_transport_central_italy.tsv")
    osm.add_public_transport_points("data/input/OpenStreetMap/public_transport_south_italy.tsv")
    osm.add_airport_straight_distance("data/input/OpenStreetMap/public_airports.tsv")

    osm.save_to_csv("data/output/osm_dataset.csv")