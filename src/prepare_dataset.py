from .utils.dataset_manager import DatasetManager


def create_dataset():
    dataset_manager = DatasetManager()

    dataset = dataset_manager.load_comuni("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.dbf")
    dataset = dataset_manager.add_tourism_data(dataset, "data/input/ISTAT/2. Dati comunali 2014-2024.xlsx")
    dataset = dataset_manager.add_extra_features(dataset, "data/output/istat_dataset.csv")
    dataset = dataset_manager.add_extra_features(dataset, "data/output/osm_dataset.csv")
    dataset = dataset_manager.add_extra_features(dataset, "data/output/other_sources_dataset.csv")

    dataset_manager.save_to_csv(dataset, "data/tourism_final_dataset.csv")



if __name__ == "__main__":
    create_dataset()