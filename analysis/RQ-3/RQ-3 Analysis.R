## ============================================================
## RQ3 -- Do tourism resources generate spatial spillovers on
##        neighbouring municipalities, and are they complementary
##        (+) or competitive (-)?
## Output: 2 plots only
##   1) sdm_direct_indirect_impacts.png
##   2) spillover_map_nature.png
## ============================================================

library(sf)
library(spdep)
library(spatialreg)
library(dplyr)
library(readr)
library(ggplot2)
library(stringr)
library(tidyr)

## 1. DATA IMPORT AND MERGE ---------------------------------------------
df <- read_csv("data/tourism_final_dataset.csv",
               col_types = cols(province_code = col_character(),
                                municipality_id = col_character())) %>%
  mutate(municipality_id = str_pad(municipality_id, 6, pad = "0"))

comuni_sf <- st_read("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp", quiet = TRUE) %>%
  mutate(municipality_id = str_pad(as.character(PRO_COM), 6, pad = "0"))

map_data <- comuni_sf %>%
  inner_join(df, by = "municipality_id") %>%
  filter(!st_is_empty(geometry)) %>%
  st_make_valid()

## 2. VARIABLE CONSTRUCTION ----------------------------------------------
map_data <- map_data %>%
  mutate(
    log_stays = log(1 + total_overnight_stays),
    log_hotel_beds = log(1 + total_hotel_beds),
    log_non_hotel_beds = log(1 + total_non_hotel_beds),
    island_municipality = factor(island_municipality, levels = c(0, 1),
                                 labels = c("Mainland", "Island")),
    altitude_zone = factor(altitude_zone),
    log_sea_coast_km = log(1 + sea_coast_km),
    log_lake_coast_km = log(1 + lake_coast_km),
    log_protected_area = log(1 + protected_areas_sqkm),
    log_museums = log(1 + museums),
    log_architecture = log(1 + architectural_features),
    log_sports = log(1 + sports_facilities),
    log_nature = log(1 + nature_based),
    log_theme_parks = log(1 + theme_parks),
    log_nightlife = log(1 + nightlife),
    log_transport_pts = log(1 + public_transport_points),
    log_airport_dist = log(1 + airport_straight_km),
    has_unesco = factor(if_else(n_unesco_sites > 0, "Yes", "No"))
  )

scale_vars <- c("log_hotel_beds", "log_non_hotel_beds",
                "log_sea_coast_km", "log_lake_coast_km", "log_protected_area",
                "log_museums", "log_architecture", "log_sports", "log_nature",
                "log_theme_parks", "log_nightlife", "log_transport_pts",
                "log_airport_dist")

map_data <- map_data %>%
  mutate(across(all_of(scale_vars), ~ as.numeric(scale(.x))))

model_formula <- log_stays ~ log_hotel_beds + log_non_hotel_beds +
  island_municipality + altitude_zone +
  log_sea_coast_km + log_lake_coast_km + log_protected_area +
  log_museums + log_architecture + log_sports + log_nature +
  log_theme_parks + log_nightlife + log_transport_pts +
  log_airport_dist + has_unesco

## Durbin formula: identical to RQ2 (no log_airport_dist)
durbin_formula <- ~ log_hotel_beds + log_non_hotel_beds +
  log_sea_coast_km + log_lake_coast_km +
  log_protected_area + log_sports + log_nature +
  log_transport_pts

## 3. SPATIAL WEIGHTS MATRIX ---------------------------------------------
nb_queen <- suppressWarnings(poly2nb(map_data, queen = TRUE))
if (sum(card(nb_queen) == 0) > 0) {
  coords <- st_coordinates(st_centroid(st_geometry(map_data)))
  nb_queen <- suppressWarnings(union.nb(nb_queen, knn2nb(knearneigh(coords, k = 1))))
}
if (!spdep::is.symmetric.nb(nb_queen, verbose = FALSE, force = TRUE)) {
  nb_queen <- make.sym.nb(nb_queen)
}
stopifnot(sum(card(nb_queen) == 0) == 0)
listw_queen <- nb2listw(nb_queen, style = "W", zero.policy = TRUE)

## 4. FIT THE SAME SDM AS IN RQ2 (method = "Matrix") --------------------
SDM <- lagsarlm(model_formula, data = map_data, listw = listw_queen,
                Durbin = durbin_formula, method = "Matrix",
                zero.policy = TRUE)

## 5. DIRECT / INDIRECT / TOTAL IMPACTS -----------------------------------
set.seed(123)
W_sparse <- as(listw_queen, "CsparseMatrix")
trMC <- trW(W_sparse, type = "MC")

safe_impacts <- function(model, tr, R = 100) {
  tryCatch(impacts(model, tr = tr, R = R), error = function(e) {
    if (grepl("not positive definite|definito positivo", conditionMessage(e), ignore.case = TRUE)) {
      impacts(model, tr = tr, R = NULL)
    } else stop(e)
  })
}

impacts_to_table <- function(imp, label) {
  res <- if (!is.null(imp$res)) imp$res else imp
  var_names <- attr(imp, "bnames")
  sim <- tryCatch(summary(imp, zstats = TRUE, short = TRUE), error = function(e) NULL)
  pvals <- if (!is.null(sim) && !is.null(sim$pzmat)) {
    data.frame(p_direct = sim$pzmat[, "Direct"],
               p_indirect = sim$pzmat[, "Indirect"],
               p_total = sim$pzmat[, "Total"])
  } else data.frame(p_direct = NA, p_indirect = NA, p_total = NA)
  cbind(data.frame(variable = var_names, direct = as.numeric(res$direct),
                   indirect = as.numeric(res$indirect), total = as.numeric(res$total),
                   model = label, row.names = NULL), pvals)
}

impSDM <- safe_impacts(SDM, trMC, R = 100)
impacts_table <- impacts_to_table(impSDM, "SDM") %>%
  mutate(spillover_type = case_when(
    is.na(p_indirect)     ~ "not tested",
    p_indirect >= 0.10    ~ "not significant",
    indirect > 0          ~ "complementary",
    indirect < 0          ~ "competitive",
    TRUE                  ~ "not significant"
  ))

## Print minimal output: impacts table (answers RQ3)
print(impacts_table)

## ============================================================
## PLOT 1 -- SDM direct vs indirect impacts
## ============================================================
impacts_plot_data <- impacts_table %>%
  select(variable, direct, indirect) %>%
  pivot_longer(cols = c(direct, indirect), names_to = "impact_type", values_to = "estimate")

p_impacts <- ggplot(impacts_plot_data,
                    aes(x = reorder(variable, estimate), y = estimate, fill = impact_type)) +
  geom_col(position = "dodge") +
  coord_flip() +
  geom_hline(yintercept = 0, linetype = "dashed", color = "grey40") +
  scale_fill_manual(values = c(direct = "#2166AC", indirect = "#B2182B"),
                    labels = c("Direct (own-municipality)", "Indirect (spillover)")) +
  labs(title = "SDM direct vs indirect impacts on tourism demand",
       subtitle = "Positive indirect = complementary spillover; negative = competitive spillover",
       x = NULL, y = "Impact on log(1 + overnight stays)", fill = NULL) +
  theme_minimal() +
  theme(plot.title = element_text(face = "bold"), legend.position = "bottom")

ggsave("analysis/RQ-3/sdm_direct_indirect_impacts.png", p_impacts, width = 10, height = 7, dpi = 300)

## ============================================================
## SPILLOVER MAP -- theta_k * (W %*% X_k) for nature-based resources
## ============================================================
map_spillover <- function(varname, title_lab) {
  theta_name <- names(SDM$coefficients)[grepl(paste0("^lag\\.", varname, "$"), names(SDM$coefficients))]
  theta <- unname(SDM$coefficients[theta_name])
  wx <- lag.listw(listw_queen, map_data[[varname]], zero.policy = TRUE)
  map_data[[paste0("spill_", varname)]] <- theta * wx
  
  lim <- max(abs(map_data[[paste0("spill_", varname)]]), na.rm = TRUE)
  ggplot(map_data) +
    geom_sf(aes(fill = .data[[paste0("spill_", varname)]]), color = "white", linewidth = 0.05) +
    scale_fill_gradient2(low = "#2166AC", mid = "white", high = "#B2182B",
                         midpoint = 0, limits = c(-lim, lim), name = expression(theta%*%WX)) +
    labs(title = paste0("Spillover from neighbours' ", title_lab),
         subtitle = paste0("theta = ", round(theta, 3), " (", 
                           impacts_table$spillover_type[impacts_table$variable == varname], ")")) +
    theme_void() +
    theme(plot.title = element_text(face = "bold", hjust = 0.5),
          plot.subtitle = element_text(hjust = 0.5),
          legend.position = "bottom")
}

## PLOT 2 -- nature-based resources spillover
p_spill_nature <- map_spillover("log_nature", "nature-based resource endowment")
ggsave("analysis/RQ-3/spillover_map_nature.png", p_spill_nature, width = 8, height = 8, dpi = 300)

## ============================================================
## RQ3 ANSWER (derived from impacts_table)
## H3 (spillovers exist) is supported if any indirect effect is
##    significant (p_indirect < 0.10).
## H4 (heterogeneous sign) is supported if impacts_table shows
##    both "complementary" and "competitive" entries.
## ============================================================