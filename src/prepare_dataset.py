from .utils.dataset_manager import DatasetManager


def create_dataset():
    dataset_manager = DatasetManager()

    dataset_manager.load_municipalities("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.dbf")
    dataset_manager.add_tourism_data("data/input/ISTAT/2. Dati comunali 2014-2024.xlsx")
    dataset_manager.add_extra_features("data/output/istat_dataset.csv")
    dataset_manager.add_extra_features("data/output/osm_dataset.csv")
    dataset_manager.add_extra_features("data/output/other_sources_dataset.csv")
    dataset_manager.fill_missing_overnight_stays("data/input/ISTAT/2. Dati comunali 2014-2024.xlsx")

    dataset_manager.save_to_csv("data/tourism_final_dataset.csv")



if __name__ == "__main__":
    create_dataset()