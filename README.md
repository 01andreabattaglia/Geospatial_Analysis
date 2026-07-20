# Spatial Autoregression (SAR) Analysis of Tourism Determinants in Italy

> ⚠️ **Project under development.** The structure, variables, and methodology described in this document are subject to change as the work progresses.

## Project goal

This project aims to conduct a **Spatial Autoregressive Model (SAR)** analysis to identify which variables — both internal to a municipality and related to neighboring municipalities (spatial spillover effects) — influence the level of tourism in Italian municipalities (*comuni*).

The underlying hypothesis is that tourism in a municipality does not depend only on its own characteristics (natural and cultural resources, infrastructure), but also on the surrounding territorial context: a municipality may benefit (or be penalized) by the presence/absence of attractions in neighboring municipalities, due to agglomeration effects, competition, or complementarity in tourism.

## Base data

- **ISTAT** — shapefiles of municipal administrative boundaries (`.shp`, `.prj`, `.dbf`, `.shx`) used as the geographic base for:
  - building the spatial contiguity/proximity weights matrix (W) needed for the SAR model;
  - producing the interactive map of results.
- **ISTAT** — municipal-level statistical data (territorial classifications, altimetric classifications, accommodation data, etc.).
- **OpenStreetMap (OSM)** — extraction of point/line/area features via the Overpass API or regional extracts, for counting and geolocating tourism-related resources.
- **UNESCO Italy site list** — for spatial join with municipal boundaries.

## Logical structure of the variables

Explanatory variables are organized according to a three-macro-category framework: **endowed resources** (not modifiable in the short term), **created resources** (resulting from investment), and **supporting factors** (enabling conditions).

### Endowed resources

| Category | Variable | Operational definition | Source | How to extract |
|---|---|---|---|---|
| Cultural/Heritage | Historic/Heritage sites and museums | Number of museums, galleries, and visitable historical/archaeological sites in the municipality | OpenStreetMap | Count `tourism=museum`, `tourism=gallery`, `historic=monument`, `historic=memorial`, `historic=ruins`, `historic=archaeological_site`, `historic=fort` |
| Cultural/Heritage | Artistic/Architectural features | Number of historic buildings of architectural/artistic value in the municipality | OpenStreetMap | Count `historic=church`, `historic=castle`, `historic=manor`, `historic=palace`, `historic=city_gate`, `tourism=artwork` |
| Cultural/Heritage | N. of UNESCO sites | Number of UNESCO sites present in the municipality | UNESCO Italy list | Spatial join between municipal boundaries and UNESCO sites |
| Natural | Coastline length (km) | Length of the municipal coastline (km) | OpenStreetMap | Extraction of `natural=coastline` and intersection with municipal territory |
| Natural | Lake shoreline length (km) | Length of lake shoreline (km) | OpenStreetMap | Extraction of `natural=water` + `water=lake` and calculation of the perimeter within the municipality |
| Natural | Island municipality dummy | 1 if the municipality is located on an island, 0 otherwise | ISTAT | ISTAT territorial classification |
| Natural | Altimetric category of the municipality | Mountain, hill, or plain municipality | ISTAT | ISTAT altimetric classification of municipalities |
| Natural | % of area in protected natural zones | Percentage of municipal surface falling within protected areas | OpenStreetMap | Overlay with `boundary=protected_area`, `leisure=nature_reserve` |

### Created resources

| Category | Variable | Operational definition | Source | How to extract |
|---|---|---|---|---|
| Tourism Infrastructure | Accommodation quality | *(to be defined)* | ISTAT | *(to be defined)* |
| Range of activities | Sports facilities | Number of sports facilities and infrastructure for summer, winter (skiing), and water-based activities (golf, tennis, alpine/nordic skiing, sailing, diving, etc.) | OpenStreetMap | Count `leisure=sports_centre`, `leisure=stadium`, `leisure=pitch`, `leisure=swimming_pool`, `sport=sports_hall`, `leisure=marina`, `leisure=slipway`, `sport=sailing`, `sport=surfing`, `sport=scuba_diving`, `piste:type=downhill`, `piste:type=nordic`, `aerialway=cable_car`, `aerialway=chair_lift` |
| Range of activities | Nature based | Number of attractions and infrastructure for hiking tourism, ecotourism, and natural/thermal areas (nature trails, protected areas, campsites, mountain huts, spas) | OpenStreetMap | Count `route=hiking`, `route=bicycle`, `leisure=nature_reserve`, `tourism=alpine_hut`, `tourism=wilderness_hut`, `tourism=camp_site`, `amenity=spa`, `leisure=spa` |
| Entertainment | Amusement/Theme parks | Number of amusement and water parks | OpenStreetMap | Count `tourism=theme_park`, `leisure=water_park` |
| Entertainment | Nightlife | Number of nightlife venues | OpenStreetMap | Count `amenity=bar`, `amenity=pub`, `amenity=nightclub` |

### Supporting Factors

| Category | Variable | Operational definition | Source | How to extract |
|---|---|---|---|---|
| General infrastructure | Local transport systems | Number of public transport stops and stations | OpenStreetMap | Count `highway=bus_stop`, `railway=station`, `railway=halt`, `public_transport=stop_position` |
| Accessibility of destination | Airport accessibility | Driving time to the nearest airport (minutes) | OpenStreetMap | Routing on the road network to `aeroway=aerodrome` via OSRM/GraphHopper |

### Events

*(section to be developed — variables related to cultural, sports, and trade fair events as a possible additional determinant of tourism)*

## Methodology (proposed)

1. **Municipal dataset construction** — extraction and processing of the variables listed above at the municipal level (OSM data via the Overpass API, ISTAT data, spatial joins with QGIS/GeoPandas).
2. **Definition of the dependent variable** — tourism indicator (e.g., tourist arrivals/overnight stays, bed capacity, tourism intensity index) from ISTAT sources.
3. **Construction of the spatial weights matrix (W)** — based on ISTAT municipal shapefiles, using contiguity criteria (queen/rook) or distance-based criteria (k-nearest neighbors, distance-band).
4. **Preliminary diagnostic tests** — check for spatial autocorrelation in the residuals of an OLS model (Moran's I, LM tests) to justify the use of a spatial model.
5. **SAR model estimation** — comparison with alternative specifications (SEM, SDM) to identify the model best suited to the data.
6. **Interpretation** — direct, indirect (spillover), and total effects of the explanatory variables.
7. **Interactive map** — visualization of results (e.g., residuals, spatial clusters, estimated effects) on an ISTAT geographic base using an interactive mapping library (e.g., Folium, Plotly, Leaflet).

## Repository structure (indicative)

```
/data
  /raw            # ISTAT shapefiles, OSM extracts, raw data
  /processed       # processed municipal dataset ready for analysis
/scripts
  01_data_extraction.py   # variable extraction from OSM/ISTAT
  02_data_join.py         # spatial joins and final dataset construction
  03_sar_model.py          # SAR model estimation and diagnostics
  04_map.py                # interactive map generation
/outputs
  /maps
  /tables
  /figures
README.md
```

## Progress status

- [x] Definition of the theoretical framework for the variables (endowed / created / supporting)
- [ ] Full extraction of variables from OSM
- [ ] Retrieval and integration of ISTAT data on accommodation and tourist overnight stays
- [ ] Definition of event-related variables
- [ ] Construction of the spatial weights matrix
- [ ] Estimation and validation of the SAR model
- [ ] Production of the interactive map
