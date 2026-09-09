# OpenStreetMap Data Extraction — Overpass API Queries

This document lists all the Overpass API (Overpass QL) queries used to extract the data stored in `data/input/OpenStreetMap`. Each query targets a specific dataset (coastlines, lakes, protected areas, points of interest, sports facilities, nature-based locations, amusement parks, nightlife venues, local transport stops, and airports) across Italy.

---

## 1. Coastline Length (Sea)

**Purpose:** Extract all coastline ways along the Italian sea border, used to compute the total length of coastline.

```overpassql
[out:json][timeout:300][maxsize:1073741824];

area["ISO3166-1"="IT"][admin_level=2]->.italia;

(
  way["natural"="coastline"](area.italia);
);
out geom;
```

---

## 2. Coastline Length (Lakes)

**Purpose:** Extract all lake geometries (ways and relations tagged as `natural=water`, `water=lake`) in Italy, used to compute the total length of lake shorelines.

```overpassql
[out:json][timeout:300][maxsize:1073741824];
area["ISO3166-1"="IT"][admin_level=2]->.italia;
(
  relation["natural"="water"]["water"="lake"](area.italia);
  way["natural"="water"]["water"="lake"](area.italia);
);
out geom;
```

---

## 3. Protected Areas (km²)

**Purpose:** Extract all protected areas and nature reserves in Italy (ways and relations), used to compute total protected surface area.

```overpassql
[out:json][timeout:300][maxsize:1073741824];
area["ISO3166-1"="IT"][admin_level=2]->.italia;
(
  relation["boundary"="protected_area"](area.italia);
  way["boundary"="protected_area"](area.italia);
  relation["leisure"="nature_reserve"](area.italia);
  way["leisure"="nature_reserve"](area.italia);
);
out geom;
```

---

## 4. Historical Sites and Museums

**Purpose:** Extract museums, galleries, monuments, memorials, ruins, archaeological sites, and forts across Italy.

```overpassql
[out:csv(::id, ::lat, ::lon, "tourism", "historic", "name")][timeout:180];
area["ISO3166-1"="IT"][admin_level=2]->.italia;

(
  node["tourism"="museum"](area.italia);
  way["tourism"="museum"](area.italia);
  relation["tourism"="museum"](area.italia);

  node["tourism"="gallery"](area.italia);
  way["tourism"="gallery"](area.italia);
  relation["tourism"="gallery"](area.italia);

  node["historic"="monument"](area.italia);
  way["historic"="monument"](area.italia);
  relation["historic"="monument"](area.italia);

  node["historic"="memorial"](area.italia);
  way["historic"="memorial"](area.italia);
  relation["historic"="memorial"](area.italia);

  node["historic"="ruins"](area.italia);
  way["historic"="ruins"](area.italia);
  relation["historic"="ruins"](area.italia);

  node["historic"="archaeological_site"](area.italia);
  way["historic"="archaeological_site"](area.italia);
  relation["historic"="archaeological_site"](area.italia);

  node["historic"="fort"](area.italia);
  way["historic"="fort"](area.italia);
  relation["historic"="fort"](area.italia);
);
out center;
```

---

## 5. Architectural Features

**Purpose:** Extract historic churches, castles, manors, palaces, city gates, and artworks across Italy.

```overpassql
[out:csv(::id, ::lat, ::lon, "tourism", "historic", "name")][timeout:180];
area["ISO3166-1"="IT"][admin_level=2]->.italia;

(
  node["historic"="church"](area.italia);
  way["historic"="church"](area.italia);
  relation["historic"="church"](area.italia);

  node["historic"="castle"](area.italia);
  way["historic"="castle"](area.italia);
  relation["historic"="castle"](area.italia);

  node["historic"="manor"](area.italia);
  way["historic"="manor"](area.italia);
  relation["historic"="manor"](area.italia);

  node["historic"="palace"](area.italia);
  way["historic"="palace"](area.italia);
  relation["historic"="palace"](area.italia);

  node["historic"="city_gate"](area.italia);
  way["historic"="city_gate"](area.italia);
  relation["historic"="city_gate"](area.italia);

  node["tourism"="artwork"](area.italia);
  way["tourism"="artwork"](area.italia);
  relation["tourism"="artwork"](area.italia);
);
out center;
```

---

## 6. Sports Facilities

**Purpose:** Extract sports centres, stadiums, pitches, swimming pools, sports halls, marinas, slipways, sailing/surfing/diving spots, ski pistes, cable cars/chair lifts, golf courses, and tennis facilities across Italy.

```overpassql
[out:csv(::id, ::lat, ::lon, "leisure", "sport", "piste:type", "aerialway", "name")][timeout:900];
area["ISO3166-1"="IT"][admin_level=2]->.italia;

(
  node["leisure"="sports_centre"](area.italia);
  way["leisure"="sports_centre"](area.italia);

  node["leisure"="stadium"](area.italia);
  way["leisure"="stadium"](area.italia);

  way["leisure"="pitch"](area.italia);

  node["leisure"="swimming_pool"](area.italia);
  way["leisure"="swimming_pool"](area.italia);

  node["sport"="sports_hall"](area.italia);
  way["sport"="sports_hall"](area.italia);

  node["leisure"="marina"](area.italia);
  way["leisure"="marina"](area.italia);

  node["leisure"="slipway"](area.italia);
  way["leisure"="slipway"](area.italia);

  node["sport"="sailing"](area.italia);
  way["sport"="sailing"](area.italia);

  node["sport"="surfing"](area.italia);

  node["sport"="scuba_diving"](area.italia);
  way["sport"="scuba_diving"](area.italia);

  way["piste:type"="downhill"](area.italia);
  relation["piste:type"="downhill"](area.italia);

  way["piste:type"="nordic"](area.italia);
  relation["piste:type"="nordic"](area.italia);

  way["aerialway"="cable_car"](area.italia);
  way["aerialway"="chair_lift"](area.italia);

  node["leisure"="golf_course"](area.italia);
  way["leisure"="golf_course"](area.italia);

  node["sport"="golf"](area.italia);
  way["sport"="golf"](area.italia);

  node["sport"="tennis"](area.italia);
  way["sport"="tennis"](area.italia);
);
out center;
```

---

## 7. Nature-Based Locations

**Purpose:** Extract hiking and bicycle routes, nature reserves, alpine/wilderness huts, campsites, and spas across Italy.

```overpassql
[out:csv(::id, ::lat, ::lon, "route", "leisure", "tourism", "amenity", "name")][timeout:900];
area["ISO3166-1"="IT"][admin_level=2]->.italia;

(
  relation["route"="hiking"](area.italia);
  way["route"="hiking"](area.italia);

  relation["route"="bicycle"](area.italia);
  way["route"="bicycle"](area.italia);

  node["leisure"="nature_reserve"](area.italia);
  way["leisure"="nature_reserve"](area.italia);
  relation["leisure"="nature_reserve"](area.italia);

  node["tourism"="alpine_hut"](area.italia);
  way["tourism"="alpine_hut"](area.italia);

  node["tourism"="wilderness_hut"](area.italia);
  way["tourism"="wilderness_hut"](area.italia);

  node["tourism"="camp_site"](area.italia);
  way["tourism"="camp_site"](area.italia);

  node["amenity"="spa"](area.italia);
  way["amenity"="spa"](area.italia);

  node["leisure"="spa"](area.italia);
  way["leisure"="spa"](area.italia);
);
out center;
```

---

## 8. Amusement / Theme Parks

**Purpose:** Extract theme parks and water parks across Italy.

```overpassql
[out:csv(::id, ::lat, ::lon, "tourism", "leisure", "name")][timeout:900];
area["ISO3166-1"="IT"][admin_level=2]->.italia;

(
  node["tourism"="theme_park"](area.italia);
  way["tourism"="theme_park"](area.italia);
  relation["tourism"="theme_park"](area.italia);

  node["leisure"="water_park"](area.italia);
  way["leisure"="water_park"](area.italia);
  relation["leisure"="water_park"](area.italia);
);
out center;
```

---

## 9. Nightlife

**Purpose:** Extract bars, pubs, and nightclubs across Italy.

```overpassql
[out:csv(::id, ::lat, ::lon, "amenity", "name")][timeout:900];
area["ISO3166-1"="IT"][admin_level=2]->.italia;

(
  node["amenity"="bar"](area.italia);
  way["amenity"="bar"](area.italia);

  node["amenity"="pub"](area.italia);
  way["amenity"="pub"](area.italia);

  node["amenity"="nightclub"](area.italia);
  way["amenity"="nightclub"](area.italia);
);
out center;
```

---

## 10. Local Transport Systems

**Purpose:** Extract bus stops, railway stations/halts, and public transport stop positions across Italy. Split into three regional batches (North, Centre, South) to keep query size manageable.

### 10.1 Northern Italy
*(Piemonte, Valle d'Aosta, Lombardia, Trentino-Alto Adige, Veneto, Friuli-Venezia Giulia, Liguria, Emilia-Romagna)*

```overpassql
[out:csv(::id, ::lat, ::lon, "highway", "railway", "public_transport", "name")][timeout:900];

(
  area["name"="Piemonte"]["admin_level"="4"];
  area["name"="Valle d'Aosta"]["admin_level"="4"];
  area["name"="Lombardia"]["admin_level"="4"];
  area["name"="Trentino-Alto Adige"]["admin_level"="4"];
  area["name"="Veneto"]["admin_level"="4"];
  area["name"="Friuli-Venezia Giulia"]["admin_level"="4"];
  area["name"="Liguria"]["admin_level"="4"];
  area["name"="Emilia-Romagna"]["admin_level"="4"];
)->.nord;

(
  node["highway"="bus_stop"](area.nord);
  node["railway"="station"](area.nord);
  way["railway"="station"](area.nord);
  node["railway"="halt"](area.nord);
  node["public_transport"="stop_position"](area.nord);
);
out center;
```

### 10.2 Central Italy
*(Toscana, Umbria, Marche, Lazio)*

```overpassql
[out:csv(::id, ::lat, ::lon, "highway", "railway", "public_transport", "name")][timeout:900];

(
  area["name"="Toscana"]["admin_level"="4"];
  area["name"="Umbria"]["admin_level"="4"];
  area["name"="Marche"]["admin_level"="4"];
  area["name"="Lazio"]["admin_level"="4"];
)->.centro;

(
  node["highway"="bus_stop"](area.centro);
  node["railway"="station"](area.centro);
  way["railway"="station"](area.centro);
  node["railway"="halt"](area.centro);
  node["public_transport"="stop_position"](area.centro);
);
out center;
```

### 10.3 Southern Italy and Islands
*(Abruzzo, Molise, Campania, Puglia, Basilicata, Calabria, Sicilia, Sardegna)*

```overpassql
[out:csv(::id, ::lat, ::lon, "highway", "railway", "public_transport", "name")][timeout:900];

(
  area["name"="Abruzzo"]["admin_level"="4"];
  area["name"="Molise"]["admin_level"="4"];
  area["name"="Campania"]["admin_level"="4"];
  area["name"="Puglia"]["admin_level"="4"];
  area["name"="Basilicata"]["admin_level"="4"];
  area["name"="Calabria"]["admin_level"="4"];
  area["name"="Sicilia"]["admin_level"="4"];
  area["name"="Sardegna"]["admin_level"="4"];
)->.sud;

(
  node["highway"="bus_stop"](area.sud);
  node["railway"="station"](area.sud);
  way["railway"="station"](area.sud);
  node["railway"="halt"](area.sud);
  node["public_transport"="stop_position"](area.sud);
);
out center;
```

---

## 11. Airports / Aerodromes

**Purpose:** Extract all aerodromes (airports, airfields, and military/civil air bases) across Italy, including IATA/ICAO codes, aerodrome type, and operator, used to build the national airports dataset.

```overpassql
[out:csv(::id, ::type, "name", "iata", "icao", "aerodrome:type", "operator", ::lat, ::lon)][timeout:300];
area["ISO3166-1"="IT"][admin_level=2]->.italia;

(
  node["aeroway"="aerodrome"](area.italia);
  way["aeroway"="aerodrome"](area.italia);
  relation["aeroway"="aerodrome"](area.italia);
);
out center;
```

**Note:** The `::type` field distinguishes `node`, `way`, and `relation` elements (larger/mapped airport boundaries are typically `way` or `relation`, while smaller airfields may be `node`). The `aerodrome:type` tag (e.g. `public`, `military/public`, `international`) and `operator` tag are not present on every feature, so some rows in the resulting CSV will have empty values for those columns.

---

## Summary Table

| # | Dataset | Output Format | Scope |
|---|---------|----------------|-------|
| 1 | Sea coastline | JSON (geometry) | Italy |
| 2 | Lake shorelines | JSON (geometry) | Italy |
| 3 | Protected areas | JSON (geometry) | Italy |
| 4 | Historical sites and museums | CSV | Italy |
| 5 | Architectural features | CSV | Italy |
| 6 | Sports facilities | CSV | Italy |
| 7 | Nature-based locations | CSV | Italy |
| 8 | Amusement/theme parks | CSV | Italy |
| 9 | Nightlife venues | CSV | Italy |
| 10 | Local transport systems | CSV | Italy (North / Centre / South) |
| 11 | Airports / aerodromes | CSV | Italy |

All queries were executed against the [Overpass API](https://overpass-api.de/) using Overpass QL syntax, targeting OpenStreetMap data restricted to the Italian national boundary (`ISO3166-1=IT`, `admin_level=2`), or to individual Italian regions (`admin_level=4`) for the transport dataset.