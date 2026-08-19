library(sf)
library(spdep)
library(spatialreg)
library(dplyr)
library(readr)
library(ggplot2)
library(stringr)
library(car)
library(patchwork)

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

durbin_formula <- ~ log_hotel_beds + log_non_hotel_beds +
  log_sea_coast_km + log_lake_coast_km +
  log_protected_area + log_sports + log_nature +
  log_transport_pts

## 3. SPATIAL WEIGHT MATRIX ---------------------------------------------
nb_queen <- suppressWarnings(poly2nb(map_data, queen = TRUE))

if (sum(card(nb_queen) == 0) > 0) {
  coords <- st_coordinates(st_centroid(st_geometry(map_data)))
  nb_queen <- suppressWarnings(
    union.nb(nb_queen, knn2nb(knearneigh(coords, k = 1)))
  )
}

if (!spdep::is.symmetric.nb(nb_queen, verbose = FALSE, force = TRUE)) {
  nb_queen <- make.sym.nb(nb_queen)
}

stopifnot(sum(card(nb_queen) == 0) == 0)
listw_queen <- nb2listw(nb_queen, style = "W", zero.policy = TRUE)

## 4. BASELINE OLS MODEL -------------------------------------------------
ols_model <- lm(model_formula, data = map_data)

# OLS MODEL
print(summary(ols_model))

## 5. SPATIAL DIAGNOSTICS ON OLS RESIDUALS -------------------------------
moran_resid <- lm.morantest(
  ols_model, listw_queen,
  zero.policy = TRUE, alternative = "greater"
)

lm_tests <- lm.RStests(
  ols_model, listw_queen,
  test = c("RSerr", "RSlag", "adjRSerr", "adjRSlag"),
  zero.policy = TRUE
)

# MORAN TEST ON OLS RESIDUALS
print(moran_resid)

# LM TESTS
print(lm_tests)

## 6. ESTIMATION OF SPATIAL MODELS ---------------------------------------
SDM <- lagsarlm(model_formula, data = map_data, listw = listw_queen,
                Durbin = durbin_formula, method = "Matrix",
                zero.policy = TRUE)

SAR <- lagsarlm(model_formula, data = map_data, listw = listw_queen,
                method = "Matrix", zero.policy = TRUE)

SDEM <- errorsarlm(model_formula, data = map_data, listw = listw_queen,
                   Durbin = durbin_formula, method = "Matrix",
                   zero.policy = TRUE)

SEM <- errorsarlm(model_formula, data = map_data, listw = listw_queen,
                  method = "Matrix", zero.policy = TRUE)

SLX <- lmSLX(model_formula, data = map_data, listw = listw_queen,
             Durbin = durbin_formula, zero.policy = TRUE)

## 7. MODEL COMPARISON ---------------------------------------------------
model_comparison <- data.frame(
  model = c("OLS", "SAR", "SEM", "SDM", "SDEM", "SLX"),
  AIC = c(AIC(ols_model), AIC(SAR), AIC(SEM),
          AIC(SDM), AIC(SDEM), AIC(SLX)),
  logLik = c(as.numeric(logLik(ols_model)), as.numeric(logLik(SAR)),
             as.numeric(logLik(SEM)), as.numeric(logLik(SDM)),
             as.numeric(logLik(SDEM)), as.numeric(logLik(SLX)))
)

# MODEL COMPARISON
print(model_comparison)

lrt_sdm_sar <- anova(SDM, SAR)
lrt_sdm_sem <- anova(SDM, SEM)

# SDM VS SAR
print(lrt_sdm_sar)

# SDM VS SEM 
print(lrt_sdm_sem)

## 8. SDM COEFFICIENTS ---------------------------------------------------
sdm_coef <- as.data.frame(coef(summary(SDM)))
sdm_coef$variable <- rownames(sdm_coef)
rownames(sdm_coef) <- NULL

sdm_coef <- sdm_coef %>%
  select(variable, everything())

summary(SDM)

## 9. RESIDUAL MAPS -----------------------------------------------------
map_data$ols_resid <- residuals(ols_model)
map_data$sdm_resid <- residuals(SDM)

lim <- max(abs(c(map_data$ols_resid, map_data$sdm_resid)), na.rm = TRUE)

p1 <- ggplot(map_data) +
  geom_sf(aes(fill = ols_resid), color = "white", linewidth = 0.05) +
  scale_fill_gradient2(low = "#2166AC", mid = "white", high = "#B2182B",
                       midpoint = 0, limits = c(-lim, lim), name = "Residual") +
  labs(title = "OLS") +
  theme_void() +
  theme(plot.title = element_text(hjust = 0.5, face = "bold"),
        legend.position = "none")

p2 <- ggplot(map_data) +
  geom_sf(aes(fill = sdm_resid), color = "white", linewidth = 0.05) +
  scale_fill_gradient2(low = "#2166AC", mid = "white", high = "#B2182B",
                       midpoint = 0, limits = c(-lim, lim), name = "Residual") +
  labs(title = "SDM") +
  theme_void() +
  theme(plot.title = element_text(hjust = 0.5, face = "bold"),
        legend.position = "none")

legend_plot <- ggplot(map_data) +
  geom_sf(aes(fill = ols_resid), color = "white", linewidth = 0.05) +
  scale_fill_gradient2(low = "#2166AC", mid = "white", high = "#B2182B",
                       midpoint = 0, limits = c(-lim, lim), name = "Residual") +
  theme_void() +
  theme(legend.position = "bottom",
        legend.key.width = unit(2, "cm"),
        legend.title = element_text(hjust = 0.5),
        legend.margin = margin(t = -10, unit = "pt"))

residual_comparison <- (p1 | p2) /
  (legend_plot + guides(fill = guide_colorbar(title = "Residual")) +
     theme(legend.position = "bottom")) +
  plot_layout(heights = c(10, 1))

ggsave("analysis/RQ-2/ols_vs_sdm_residuals.png",
       residual_comparison, width = 14, height = 8, dpi = 300)