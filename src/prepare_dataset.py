from .utils.dataset_manager import DatasetManager


def create_dataset():
    dataset_manager = DatasetManager()

    dataset = dataset_manager.load_comuni(
        "data/input/Com01012024_g/Com01012024_g_WGS84.dbf"
    )

    dataset = dataset_manager.add_tourism_data(
        dataset,
        "data/input/2. Dati comunali 2014-2024.xlsx"
    )

    dataset_manager.save_to_csv(
        dataset,
        "data/tourism_final_dataset.csv",
        index=False
    )


if __name__ == "__main__":
    create_dataset()