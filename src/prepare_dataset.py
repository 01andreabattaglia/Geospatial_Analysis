from .utils.dataset_manager import DatasetManager

dataset_manager = DatasetManager()

dataset = dataset_manager.load_comuni("data/input/Limiti01012024_g/Com01012024_g/Com01012024_g_WGS84.dbf")
dataset = dataset_manager.add_tourism_data(dataset, "data/input/2. Dati comunali 2014-2024.xlsx")
dataset = dataset_manager.add_comuni_characteristics(dataset, "data/input/Comuni - Caratteristiche del territorio Data Indagine 31-12-2024 Stampa 20062026171759.csv")
dataset_manager.save_to_csv(dataset, "data/tourism_final_dataset.csv", index=False)