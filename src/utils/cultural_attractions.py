import re
import pandas as pd
from unidecode import unidecode


# eccezioni manuali: chiave = nome normalizzato nel CSV,
# valore = nome normalizzato nel dataset
ECCEZIONI_COMUNI = {
    # Alto Adige
    # "bolzanobozen": "bolzanobozen",
    # "meranomeran": "merano",
    # "bressanonebrixen": "bressanone",
    # "brunicobruneck": "brunico",
    "meltinamoelten": "meltinamolten",
    "funesvillnoess": "funesvillnoss",

    # Emilia-Romagna
    "porrettaterme": "altorenoterme",
    "bazzano": "valsamoggia",
    "busana": "ventasso",
    "castellodiserravalle": "valsamoggia",
    "caminata": "altavaltidone",
    "poggioberni": "poggiotorriana",
    "santagostino": "terredelreno",
    "massafiscaglia": "fiscaglia",
    "migliarino": "fiscaglia",
    "montescudo": "montescudomontecolombo",
    "zibello": "polesinezibello",

    # Marche
    "barchi": "terreroveresche",
    "saltara": "collialmetauro",
    "montemaggiorealmetauro": "collialmetauro",
    "sangiorgiodipesaro": "terreroveresche",
    "orcianodipesaro": "terreroveresche",
    "piagge": "terreroveresche",
    "sassocorvaro": "sassocorvaroauditore",
    "auditore": "sassocorvaroauditore",
    "colbordolo": "vallefoglia",
    "monteciccardo": "pesaro",
    "ripe": "trecastelli",

    # Toscana
    "barberinovaldelsa": "barberinotavarnelle",
    "tavarnellevaldipesa": "barberinotavarnelle",
    "figlinevaldarno": "figlineeincisavaldarno",
    "incisainvaldarno": "figlineeincisavaldarno",
    "castelfrancodisopra": "castelfrancopiandisco",
    "stia": "pratovecchiostia",
    "scarperia": "scarperiaesanpiero",
    "sanpieroasieve": "scarperiaesanpiero",
    "crespina": "crespinalorenzana",
    "lari": "cascianatermelari",
    "sangiovannidasso": "montalcino",

    # Trentino-Alto Adige
    "fieradiprimiero": "primierosanmartinodicastrozza",
    "tonadico": "primierosanmartinodicastrozza",
    "pozzadifassa": "sangiovannidifassasenjan",
    "vigodifassa": "sangiovannidifassasenjan",
    "pievedibono": "pievedibonoprezzo",
    "sanlorenzoinbanale": "sanlorenzodorsino",
    "daone": "valdaone",
    "bersone": "valdaone",

    # Veneto
    "mel": "borgovalbelluna",
    "castellavazzo": "longarone",
    "valstagna": "valbrenta",
    "lusiana": "lusianaconco",
    "mossano": "barbaranomossano",

    # Lombardia
    "lenno": "tremezzina",
    "tremezzo": "tremezzina",
    "maccagno": "maccagnoconpinoeveddasca",
    "lanzodintelvi": "altavalleintelvi",
    "piadena": "piadenadrizzona",

    # Piemonte
    "gavazzana": "cassanospinola",
    "castellania": "castellaniacoppi",
    "castellar": "saluzzo",
    "piovera": "alluvionipiovera",
    "rimasangiuseppe": "alagnavalsesia",
    "rivavaldobbia": "alagnavalsesia",

    # Calabria
    "coriglianocalabro": "coriglianorossano",
    "rossano": "coriglianorossano",
    "serrapedace": "casalidelmanco",

    # Friuli Venezia Giulia
    "sgonico": "sgonicozgonik",
    "monrupino": "monrupinorepentabor",
    "treppocarnico": "treppoligosullo",

    # Abruzzo
    "popoli": "popoliterme",

    # Campania
    "montoroinferiore": "montoro",

    # Liguria
    "carpasio": "montaltocarpasio",
    "ortonovo": "luni",

    # Lombardia / Mantova
    "borgofrancosulpo": "borgocarbonara",
    "felonica": "borgocarbonara",
    "revere": "borgocarbonara",

    # Toscana / Elba
    "riomarina": "rio",
    "rionellelba": "rio",

    # Marche
    "pievebovigliana": "valfornace",
    "trivero": "valdilana",
    "presicce": "presicceacquarica",
    "virgilio": "borgovirgilio",

    # Friuli Venezia Giulia (nota: doppione concettuale già sopra)
    "duinoaurisina": "duinoaurisinadevinnabrezina",
}


MAPPA_MACRO = {
    # Musei / collezioni
    "Museo, Galleria e/o raccolta": "numero_musei_collezioni",
    "Archivio di Stato": "numero_musei_collezioni",
    "Archivio": "numero_musei_collezioni",
    "Biblioteca Statale": "numero_musei_collezioni",
    "Biblioteca": "numero_musei_collezioni",
    "I tesori della Cultura": "numero_musei_collezioni",

    # Archeologia
    "Area Archeologica": "numero_patrimoni_archeologici",
    "Parco Archeologico": "numero_patrimoni_archeologici",
    "Monumento di Archeologia Industriale": "numero_patrimoni_archeologici",

    # Patrimonio storico / architettonico
    "Chiesa o edificio di culto": "numero_architettura_patrimoni_storici",
    "Villa o Palazzo di interesse storico o artistico": "numero_architettura_patrimoni_storici",
    "Architettura Civile": "numero_architettura_patrimoni_storici",
    "Architettura Fortificata": "numero_architettura_patrimoni_storici",
    "Monumento": "numero_architettura_patrimoni_storici",
    "Monumento Funerario": "numero_architettura_patrimoni_storici",
    "Parco o Giardino di interesse storico o artistico": "numero_architettura_patrimoni_storici",
    "Altro": "numero_architettura_patrimoni_storici",
}


MACRO_COLS = [
    "numero_musei_collezioni",
    "numero_patrimoni_archeologici",
    "numero_architettura_patrimoni_storici",
]


def normalize_name(s: str) -> str:
    """
    Normalizza un nome comune per il matching fuzzy:
    - rimuove accenti
    - converte in minuscolo
    - rimuove spazi, apostrofi, trattini e punteggiatura
    """
    s = unidecode(str(s)).lower()
    s = re.sub(r"[^a-z0-9]+", "", s)
    return s


def load_cultural_attractions_pivot(csv_path: str) -> pd.DataFrame:
    """
    Legge il CSV delle attrazioni culturali e restituisce
    un dataframe pivotato per comune.
    """
    df = pd.read_csv(csv_path)

    required_columns = ["comune", "tipologia", "numeroLuoghi"]

    missing = [c for c in required_columns if c not in df.columns]
    if missing:
        raise ValueError(f"Colonne mancanti nel CSV: {missing}")

    df["comune"] = (
        df["comune"]
        .astype(str)
        .str.strip()
        .str.replace("_", " ", regex=False)
    )

    df["numeroLuoghi"] = (
        pd.to_numeric(df["numeroLuoghi"], errors="coerce")
        .fillna(0)
        .astype(int)
    )

    df["macro_categoria"] = df["tipologia"].map(MAPPA_MACRO)

    unmapped = df.loc[df["macro_categoria"].isna(), "tipologia"].unique()

    if len(unmapped) > 0:
        print(
            f"Attenzione: tipologie non mappate e ignorate: "
            f"{list(unmapped)}"
        )

    df = df.dropna(subset=["macro_categoria"])

    pivot = (
        df.pivot_table(
            index="comune",
            columns="macro_categoria",
            values="numeroLuoghi",
            aggfunc="sum",
            fill_value=0,
        )
        .reindex(columns=MACRO_COLS, fill_value=0)
        .reset_index()
    )

    return pivot