library(sf)
library(spdep)
library(spatialreg)
library(dplyr)
library(readr)
library(ggplot2)
library(stringr)
library(car)
library(patchwork)

## ============================================================
## RQ3 — Does municipal tourism endowment generate spillover
## effects on neighbouring municipalities' tourism demand,
## and are these effects complementary or competitive?
##
## Model excludes has_hotel_beds and high_end_pct_centered:
## RQ3 focuses on resource ENDOWMENT (cultural, natural,
## entertainment, accessibility), not accommodation quality mix.
## ============================================================

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

## Mean equation: has_hotel_beds and high_end_pct_centered EXCLUDED
model_formula <- log_stays ~ log_hotel_beds + log_non_hotel_beds +
  island_municipality + altitude_zone +
  log_sea_coast_km + log_lake_coast_km + log_protected_area +
  log_museums + log_architecture + log_sports + log_nature +
  log_theme_parks + log_nightlife + log_transport_pts +
  log_airport_dist + has_unesco

## WX (Durbin) equation: high_end_pct_centered EXCLUDED
## (has_hotel_beds was never lagged in the original spec either)
durbin_formula <- ~ log_hotel_beds + log_non_hotel_beds +
  log_sea_coast_km + log_lake_coast_km +
  log_protected_area + log_sports + log_nature +
  log_transport_pts + log_airport_dist

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
summary(ols_model)

## 5. SPATIAL DIAGNOSTICS ON OLS RESIDUALS -------------------------------
## Following Elhorst (2010) / slide 29-31: OLS -> LM tests -> pick direction
moran_resid <- lm.morantest(ols_model, listw_queen, zero.policy = TRUE, alternative = "greater")
print(moran_resid)

lm_tests <- lm.RStests(ols_model, listw_queen,
                       test = c("RSerr", "RSlag", "adjRSerr", "adjRSlag"),
                       zero.policy = TRUE)
print(lm_tests)

## 6. ESTIMATION OF SPATIAL MODELS ---------------------------------------
## Estimate the full set (SDM, SAR, SDEM, SEM, SLX) so the LRT-based
## Elhorst decision tree can be applied regardless of what the LM tests say
SDM <- lagsarlm(model_formula, data = map_data, listw = listw_queen,
                Durbin = durbin_formula, method = "Matrix", zero.policy = TRUE)
SAR <- lagsarlm(model_formula, data = map_data, listw = listw_queen,
                method = "Matrix", zero.policy = TRUE)
SDEM <- errorsarlm(model_formula, data = map_data, listw = listw_queen,
                   Durbin = durbin_formula, method = "Matrix", zero.policy = TRUE)
SEM <- errorsarlm(model_formula, data = map_data, listw = listw_queen,
                  method = "Matrix", zero.policy = TRUE)
SLX <- lmSLX(model_formula, data = map_data, listw = listw_queen,
             Durbin = durbin_formula, zero.policy = TRUE)

## 6b. DIAGNOSTICS FOR THE NaN-HESSIAN WARNING ---------------------------
## Since SAR (no Durbin/WX terms at all) ALSO throws this warning, the
## cause is NOT X-vs-WX collinearity -- it must be inside model_formula's
## own design matrix. Check for rank deficiency / near-collinearity there.

## 1) Is the design matrix full rank? If rank < ncol, some column is an
##    exact linear combination of others (perfect collinearity).
X_design <- model.matrix(model_formula, data = map_data)
cat("Design matrix: ", ncol(X_design), " columns, rank = ",
    qr(X_design)$rank, "\n", sep = "")
if (qr(X_design)$rank < ncol(X_design)) {
  cat("--> RANK DEFICIENT. Columns involved:\n")
  print(alias(ols_model)$Complete)
}

## 2) VIF on the OLS model (aliased/near-perfectly-collinear terms will
##    error out here, which is itself diagnostic)
vif_result <- tryCatch(car::vif(ols_model), error = function(e) e)
print(vif_result)

## 3) Any near-zero-variance columns (e.g. a dummy with almost all one
##    level) or empty factor-level combinations?
sapply(map_data %>% st_drop_geometry() %>%
         select(island_municipality, altitude_zone, has_unesco),
       table)

## 4) Any non-finite values feeding into the model (Inf/-Inf/NaN)?
predictor_cols <- all.vars(model_formula)[-1]
non_finite <- sapply(map_data %>% st_drop_geometry() %>% select(all_of(predictor_cols)),
                     function(x) if (is.numeric(x)) sum(!is.finite(x)) else NA)
cat("Non-finite values per numeric predictor:\n")
print(non_finite[!is.na(non_finite) & non_finite > 0])

cat("Non-finite values in response (log_stays): ",
    sum(!is.finite(map_data$log_stays)), "\n", sep = "")

## 7. MODEL COMPARISON ---------------------------------------------------
model_comparison <- data.frame(
  model = c("OLS", "SAR", "SEM", "SDM", "SDEM", "SLX"),
  AIC = c(AIC(ols_model), AIC(SAR), AIC(SEM), AIC(SDM), AIC(SDEM), AIC(SLX)),
  logLik = c(as.numeric(logLik(ols_model)), as.numeric(logLik(SAR)),
             as.numeric(logLik(SEM)), as.numeric(logLik(SDM)),
             as.numeric(logLik(SDEM)), as.numeric(logLik(SLX)))
)
print(model_comparison)

## LRT: can SDM be reduced to SAR (H0: theta = 0)?
lrt_sdm_sar <- anova(SDM, SAR)
## LRT: can SDM be reduced to SEM (H0: theta + rho*beta = 0)?
lrt_sdm_sem <- anova(SDM, SEM)
print(lrt_sdm_sar)
print(lrt_sdm_sem)

## Additional nested tests per Elhorst's decision tree:
## SDEM -> SEM (H0: theta = 0), SDEM -> SLX (H0: lambda = 0)
lrt_sdem_sem <- anova(SDEM, SEM)
print(lrt_sdem_sem)

## 8. DIRECT AND INDIRECT IMPACTS ----------------------------------------
## This is the core evidence for RQ3: indirect impacts quantify
## spillovers onto neighbouring municipalities; their SIGN indicates
## whether the spillover is complementary (+) or competitive (-).
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

impacts_to_table <- function(imp, label) {
  res <- if (!is.null(imp$res)) imp$res else imp
  var_names <- attr(imp, "bnames")
  
  sim <- tryCatch(summary(imp, zstats = TRUE, short = TRUE), error = function(e) NULL)
  pvals <- if (!is.null(sim) && !is.null(sim$pzmat)) {
    data.frame(p_direct = sim$pzmat[, "Direct"],
               p_indirect = sim$pzmat[, "Indirect"],
               p_total = sim$pzmat[, "Total"])
  } else {
    data.frame(p_direct = NA, p_indirect = NA, p_total = NA)
  }
  
  out <- data.frame(
    variable = var_names,
    direct = as.numeric(res$direct),
    indirect = as.numeric(res$indirect),
    total = as.numeric(res$total),
    model = label,
    row.names = NULL
  )
  cbind(out, pvals)
}

## Use whichever spatial model the Elhorst procedure above selects.
## Both SAR and SDM impacts are reported here for completeness/robustness.
impSAR <- safe_impacts(SAR, trMC, R = 100)
impSDM <- safe_impacts(SDM, trMC, R = 100)

impacts_table <- rbind(impacts_to_table(impSAR, "SAR"),
                       impacts_to_table(impSDM, "SDM"))

## Flag spillover direction: complementary (indirect > 0 & significant),
## competitive (indirect < 0 & significant), or not significant
impacts_table <- impacts_table %>%
  mutate(
    spillover_type = case_when(
      is.na(p_indirect) ~ "not tested",
      p_indirect >= 0.10 ~ "not significant",
      indirect > 0 ~ "complementary",
      indirect < 0 ~ "competitive",
      TRUE ~ "not significant"
    )
  )

print(impacts_table)

## 9. RESIDUAL MAPS -------------------------------------------------------
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

ggsave("analysis/RQ-3/ols_vs_sdm_residuals.png",
       residual_comparison, width = 14, height = 8, dpi = 300)

## 9b. MORAN SCATTERPLOT OF SDM RESIDUALS ---------------------------------
## Checks whether the SDM has actually absorbed the spatial autocorrelation
## that was present in the OLS residuals (slide 36 style diagnostic)
moran_plot_sdm <- moran.plot(map_data$sdm_resid, listw_queen, zero.policy = TRUE,
                             plot = FALSE)

moran_scatter <- ggplot(moran_plot_sdm, aes(x = x, y = wx)) +
  geom_point(aes(color = is_inf), alpha = 0.6, size = 1.6) +
  geom_smooth(method = "lm", se = FALSE, color = "#B2182B", linewidth = 0.8) +
  geom_vline(xintercept = mean(map_data$sdm_resid, na.rm = TRUE),
             linetype = "dashed", color = "grey50") +
  geom_hline(yintercept = mean(moran_plot_sdm$wx, na.rm = TRUE),
             linetype = "dashed", color = "grey50") +
  scale_color_manual(values = c(`TRUE` = "#B2182B", `FALSE` = "#2166AC"),
                     guide = "none") +
  labs(title = "Moran scatterplot of SDM residuals",
       subtitle = "No residual clustering expected if spatial dependence is fully captured",
       x = "SDM residual", y = "Spatial lag of SDM residual") +
  theme_minimal() +
  theme(plot.title = element_text(face = "bold"))

ggsave("analysis/RQ-3/moran_scatterplot_sdm_residuals.png",
       moran_scatter, width = 8, height = 7, dpi = 300)

## 10. IMPACTS PLOT: direct vs indirect effects by variable ---------------
impacts_plot_data <- impacts_table %>%
  filter(model == "SDM") %>%
  select(variable, direct, indirect) %>%
  tidyr::pivot_longer(cols = c(direct, indirect),
                      names_to = "impact_type", values_to = "estimate")

impacts_plot <- ggplot(impacts_plot_data,
                       aes(x = reorder(variable, estimate), y = estimate,
                           fill = impact_type)) +
  geom_col(position = "dodge") +
  coord_flip() +
  geom_hline(yintercept = 0, linetype = "dashed", color = "grey40") +
  scale_fill_manual(values = c(direct = "#2166AC", indirect = "#B2182B"),
                    labels = c("Direct (own-municipality)", "Indirect (spillover)")) +
  labs(title = "SDM direct vs indirect impacts on tourism demand",
       subtitle = "Positive indirect = complementary spillover; negative = competitive spillover",
       x = NULL, y = "Impact on log(1 + overnight stays)", fill = NULL) +
  theme_minimal() +
  theme(plot.title = element_text(face = "bold"),
        legend.position = "bottom")

ggsave("analysis/RQ-3/sdm_direct_indirect_impacts.png",
       impacts_plot, width = 10, height = 7, dpi = 300)