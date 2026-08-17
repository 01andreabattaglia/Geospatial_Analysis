library(sf)
library(spdep)
library(spatialreg)
library(dplyr)
library(readr)
library(ggplot2)
library(stringr)
library(broom)
library(car)
library(reshape2)

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
## high_end_hotel_beds_pct: 0 is structural for municipalities with no
## hotel beds at all ("undefined", not "0% high-end"). Split into a
## dummy (has_hotel_beds) + a share centred among hotel-owning
## municipalities (high_end_pct_centered, forced to 0 otherwise),
## entered additively to avoid aliased coefficients.
map_data <- map_data %>%
  mutate(
    log_stays = log(1 + total_overnight_stays),
    log_hotel_beds     = log(1 + total_hotel_beds),
    log_non_hotel_beds = log(1 + total_non_hotel_beds),
    has_hotel_beds = factor(if_else(total_hotel_beds > 0, "Yes", "No")),
    island_municipality = factor(island_municipality, levels = c(0, 1),
                                 labels = c("Mainland", "Island")),
    altitude_zone      = factor(altitude_zone),
    log_sea_coast_km   = log(1 + sea_coast_km),
    log_lake_coast_km  = log(1 + lake_coast_km),
    log_protected_area = log(1 + protected_areas_sqkm),
    log_museums        = log(1 + museums),
    log_architecture   = log(1 + architectural_features),
    log_sports         = log(1 + sports_facilities),
    log_nature         = log(1 + nature_based),
    log_theme_parks    = log(1 + theme_parks),
    log_nightlife      = log(1 + nightlife),
    log_transport_pts  = log(1 + public_transport_points),
    log_airport_dist   = log(1 + airport_straight_km),
    has_unesco         = factor(if_else(n_unesco_sites > 0, "Yes", "No"))
  )

high_end_mean <- mean(map_data$high_end_hotel_beds_pct[map_data$has_hotel_beds == "Yes"], na.rm = TRUE)

map_data <- map_data %>%
  mutate(high_end_pct_centered = if_else(has_hotel_beds == "Yes",
                                         high_end_hotel_beds_pct - high_end_mean, 0))

model_formula <- log_stays ~ log_hotel_beds + log_non_hotel_beds +
  has_hotel_beds + high_end_pct_centered +
  island_municipality + altitude_zone +
  log_sea_coast_km + log_lake_coast_km + log_protected_area +
  log_museums + log_architecture + log_sports + log_nature +
  log_theme_parks + log_nightlife + log_transport_pts +
  log_airport_dist + has_unesco

## Only continuous regressors are spatially lagged (WX block)
durbin_formula <- ~ log_hotel_beds + log_non_hotel_beds +
  high_end_pct_centered + log_sea_coast_km + log_lake_coast_km +
  log_protected_area + log_museums + log_architecture + log_sports +
  log_nature + log_theme_parks + log_nightlife + log_transport_pts +
  log_airport_dist

## 3. SPATIAL WEIGHT MATRIX (queen contiguity) ----------------------------
nb_queen <- poly2nb(map_data, queen = TRUE)
if (sum(card(nb_queen) == 0) > 0) {
  coords <- st_coordinates(st_centroid(st_geometry(map_data)))
  nb_queen <- union.nb(nb_queen, knn2nb(knearneigh(coords, k = 1)))
}
if (!spdep::is.symmetric.nb(nb_queen, verbose = FALSE, force = TRUE)) {
  nb_queen <- make.sym.nb(nb_queen)
}
listw_queen <- nb2listw(nb_queen, style = "W", zero.policy = TRUE)

## 4. BASELINE OLS MODEL ---------------------------------------------------
ols_model <- lm(model_formula, data = map_data)
ols_model


## Collinearity check: VIF on the OLS design matrix (type = "predictor"
## gives a generalized VIF, adjusted for degrees of freedom, correctly
## handling multi-level factors like altitude_zone). Rule of thumb:
## VIF > 5 warrants attention.
vif_table <- as.data.frame(vif(ols_model, type = "predictor"))
vif_table

## Pairwise correlation among the continuous log-variables, saved as a
## colour-coded heatmap.
cont_vars <- map_data %>%
  st_drop_geometry() %>%
  select(log_hotel_beds, log_non_hotel_beds, high_end_pct_centered,
         log_sea_coast_km, log_lake_coast_km, log_protected_area,
         log_museums, log_architecture, log_sports, log_nature,
         log_theme_parks, log_nightlife, log_transport_pts, log_airport_dist)

cor_matrix <- cor(cont_vars, use = "pairwise.complete.obs")
round(cor_matrix, 2)

cor_long <- melt(cor_matrix, varnames = c("Var1", "Var2"), value.name = "Correlation")

ggplot(cor_long, aes(x = Var1, y = Var2, fill = Correlation)) +
  geom_tile(color = "white") +
  geom_text(aes(label = round(Correlation, 2)), size = 2.8) +
  scale_fill_gradient2(low = "#2c7bb6", mid = "white", high = "#d7191c",
                       midpoint = 0, limits = c(-1, 1)) +
  labs(title = "Correlation matrix - continuous regressors", x = NULL, y = NULL) +
  theme_minimal() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

ggsave("analysis/RQ-2/correlation_matrix.png", width = 9, height = 8, dpi = 200)

## 5. SPATIAL DIAGNOSTICS ON OLS RESIDUALS ---------------------------------
map_data$ols_resid <- residuals(ols_model)

moran_resid <- lm.morantest(ols_model, listw_queen, zero.policy = TRUE, alternative = "greater")
moran_resid

## LM / robust-LM tests: point to the SAR or SEM branch
lm_tests <- lm.RStests(ols_model, listw_queen,
                       test = c("RSerr", "RSlag", "adjRSerr", "adjRSlag"),
                       zero.policy = TRUE)
lm_tests_list <- lm_tests$results
if (is.null(lm_tests_list)) lm_tests_list <- lm_tests
lm_tests_list <- lm_tests_list[sapply(lm_tests_list, inherits, "htest")]

lm_tests_table <- do.call(rbind, lapply(names(lm_tests_list), function(nm) {
  res <- lm_tests_list[[nm]]
  data.frame(test = nm, statistic = unname(res$statistic),
             parameter = unname(res$parameter), p_value = res$p.value)
}))
lm_tests_table

## 6. ESTIMATION OF THE CANDIDATE MODELS -----------------------------------
SDM  <- lagsarlm(model_formula, data = map_data, listw = listw_queen,
                 Durbin = durbin_formula, method = "Matrix", zero.policy = TRUE)
SAR  <- lagsarlm(model_formula, data = map_data, listw = listw_queen,
                 method = "Matrix", zero.policy = TRUE)
SDEM <- errorsarlm(model_formula, data = map_data, listw = listw_queen,
                   Durbin = durbin_formula, method = "Matrix", zero.policy = TRUE)
SEM  <- errorsarlm(model_formula, data = map_data, listw = listw_queen,
                   method = "Matrix", zero.policy = TRUE)
SLX  <- lmSLX(model_formula, data = map_data, listw = listw_queen,
              Durbin = durbin_formula, zero.policy = TRUE)

## 7. DIRECT / INDIRECT / TOTAL IMPACTS (SAR, SDM) -------------------------
set.seed(123)
W_sparse <- as(listw_queen, "CsparseMatrix")
trMC <- trW(W_sparse, type = "MC")

safe_impacts <- function(model, tr, R = 100) {
  tryCatch({
    impacts(model, tr = tr, R = R)
  }, error = function(e) {
    if (grepl("not positive definite|definito positivo", conditionMessage(e), ignore.case = TRUE)) {
      impacts(model, tr = tr, R = NULL)
    } else stop(e)
  })
}

## Variable names come from the top-level "bnames" attribute, since the
## individual direct/indirect/total vectors are not reliably named
## (unnamed for SAR's $res, named for SDM's top-level list).
impacts_to_table <- function(imp, label) {
  res <- if (!is.null(imp$res)) imp$res else imp
  var_names <- attr(imp, "bnames")
  
  data.frame(
    variable = var_names,
    direct   = as.numeric(res$direct),
    indirect = as.numeric(res$indirect),
    total    = as.numeric(res$total),
    model    = label,
    row.names = NULL
  )
}

impSAR <- safe_impacts(SAR, trMC, R = 100)
impSDM <- safe_impacts(SDM, trMC, R = 100)

impacts_table <- rbind(impacts_to_table(impSAR, "SAR"),
                       impacts_to_table(impSDM, "SDM"))
impacts_table

## 8. MODEL SELECTION - LR TESTS AND AIC COMPARISON (Elhorst 2010) --------
lrt_sdm_sar  <- anova(SDM, SAR)
lrt_sdm_sem  <- anova(SDM, SEM)
lrt_sdem_sem <- anova(SDEM, SEM)

lrt_table <- rbind(
  data.frame(comparison = "SDM vs SAR",  as.data.frame(lrt_sdm_sar)),
  data.frame(comparison = "SDM vs SEM",  as.data.frame(lrt_sdm_sem)),
  data.frame(comparison = "SDEM vs SEM", as.data.frame(lrt_sdem_sem))
)
lrt_table

model_comparison <- data.frame(
  model  = c("OLS", "SAR", "SEM", "SDM", "SDEM", "SLX"),
  AIC    = c(AIC(ols_model), AIC(SAR), AIC(SEM), AIC(SDM), AIC(SDEM), AIC(SLX)),
  logLik = c(as.numeric(logLik(ols_model)), as.numeric(logLik(SAR)),
             as.numeric(logLik(SEM)), as.numeric(logLik(SDM)),
             as.numeric(logLik(SDEM)), as.numeric(logLik(SLX)))
)
model_comparison

## 9. FINAL MODEL -----------------------------------------------------------
## Decision rule (apply once lrt_table / lm_tests_table are inspected):
##  - both anova(SDM,SAR) and anova(SDM,SEM) reject H0 -> keep SDM
##  - anova(SDM,SAR) does not reject H0 and LM points to SAR -> keep SAR
##  - anova(SDM,SEM) does not reject H0 and LM points to SEM -> check
##    anova(SDEM,SEM); prefer SDEM if the lagged-X block is significant,
##    otherwise SEM

final_model <- SAR   # <-- update after inspecting lrt_table / lm_tests_table
final_model_name <- "SAR"

final_model

map_data$final_resid <- residuals(final_model)

shared_resid_limit <- max(abs(c(map_data$ols_resid, map_data$final_resid)), na.rm = TRUE)
shared_resid_limits <- c(-shared_resid_limit, shared_resid_limit)

ggplot(map_data) +
  geom_sf(aes(fill = ols_resid), color = "white", linewidth = 0.05) +
  scale_fill_gradient2(low = "#0000FF", mid = "white", high = "#FF0000",
                       midpoint = 0, limits = shared_resid_limits, name = "OLS residual") +
  labs(title = "Spatial distribution of OLS residuals") +
  theme_minimal()
ggsave("analysis/RQ-2/ols_residuals_map.png", width = 9, height = 9, dpi = 200)

ggplot(map_data) +
  geom_sf(aes(fill = final_resid), color = "white", linewidth = 0.05) +
  scale_fill_gradient2(low = "#0000FF", mid = "white", high = "#FF0000",
                       midpoint = 0, limits = shared_resid_limits, name = paste(final_model_name, "residual")) +
  labs(title = paste0("Spatial distribution of ", final_model_name, " residuals")) +
  theme_minimal()
ggsave("analysis/RQ-2/final_model_residuals_map.png", width = 9, height = 9, dpi = 200)

moran_final_resid <- moran.test(map_data$final_resid, listw_queen,
                                zero.policy = TRUE, alternative = "greater")
moran_final_resid