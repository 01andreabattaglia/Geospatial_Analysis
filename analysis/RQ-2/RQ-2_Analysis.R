## ============================================================
## RQ2 - Which factors explain overnight stays, net of spatial
##       dependence? Model selection (Elhorst 2010 strategy) among
##       OLS / SAR / SEM / SDM / SDEM / SLX
##
## Rewritten to follow the course lab's workflow and function choices:
##   - lm.RStests()  (not the older lm.LMtests()) for the LM/robust-LM
##     diagnostics on the OLS residuals
##   - lagsarlm(..., Durbin = TRUE)   for the SDM
##   - errorsarlm(..., Durbin = TRUE) for the SDEM
##   - anova(SDM, SAR) / anova(SDM, SEM) / anova(SDEM, SEM) for the
##     nested likelihood-ratio tests (Elhorst 2010 selection strategy)
##   - impacts() for direct/indirect/total effects of SAR and SDM
## ============================================================
## Required packages:
##   install.packages(c("sf", "spdep", "spatialreg", "dplyr", "readr",
##                       "ggplot2", "stringr", "car", "caret", "broom"))
## ============================================================

library(sf)
library(spdep)
library(spatialreg)   # lagsarlm, errorsarlm, lmSLX, anova(), impacts()
library(dplyr)
library(readr)
library(ggplot2)
library(stringr)
library(car)           # vif(), alias()
library(caret)         # findLinearCombos() - pinpoints aliased columns
library(broom)

dir.create("analysis/RQ-2", recursive = TRUE, showWarnings = FALSE)

## ------------------------------------------------------------
## 0. DATA IMPORT AND MERGE (same procedure as in RQ1)
## ------------------------------------------------------------

df <- read_csv("data/tourism_final_dataset.csv",
               col_types = cols(
                 province_code   = col_character(),
                 municipality_id = col_character()
               )) %>%
  mutate(municipality_id = str_pad(municipality_id, width = 6, pad = "0"))

comuni_sf <- st_read("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp",
                     quiet = TRUE) %>%
  mutate(municipality_id = str_pad(as.character(PRO_COM), width = 6, pad = "0"))

map_data <- comuni_sf %>%
  inner_join(df, by = "municipality_id") %>%
  filter(!st_is_empty(geometry)) %>%
  st_make_valid()

cat("Municipalities used in the RQ2 analysis:", nrow(map_data), "\n")

## ------------------------------------------------------------
## 1. VARIABLE CONSTRUCTION
## ------------------------------------------------------------
## Modelling choices (unchanged from the previous version, kept here for
## a self-contained script):
##  - log(1+x) for the dependent variable and for count-type/skewed
##    regressors, consistent with the gravity-type tourism-demand models
##    in the literature (Pompili, Pisati & Lorenzini 2019; Zamparini,
##    Vergori & Arima 2017; Yang & Wong 2012).
##  - `total_population` EXCLUDED: strongly collinear with accommodation
##    capacity and attractor counts (a pure city-size effect, not an
##    attractiveness effect).
##  - `unesco_sites` (text field with site NAMES) EXCLUDED; only the
##    count `n_unesco_sites` is used, recoded as a dummy `has_unesco`
##    since it is zero for the vast majority of municipalities.
##  - `altitude_zone` and `island_municipality` treated as CATEGORICAL
##    (factors).
##  - `high_end_hotel_beds_pct`: recoded as a dummy `has_hotel_beds`
##    (Yes/No, absorbing the structural "no hotel beds" case) plus a
##    mean-centred continuous share `high_end_pct_centered`, set to
##    exactly 0 where has_hotel_beds == "No". It enters as a plain
##    additive term (no explicit ":" interaction): R would otherwise
##    expand "A + A:B" into one slope column per level of A, including
##    the (constant-zero) reference level, producing an aliased
##    coefficient - see the previous iteration of this script for the
##    diagnostic that uncovered this.

map_data <- map_data %>%
  mutate(
    ## dependent variable
    log_stays = log(1 + total_overnight_stays),
    
    ## accommodation capacity (log)
    log_hotel_beds     = log(1 + total_hotel_beds),
    log_non_hotel_beds = log(1 + total_non_hotel_beds),
    
    ## high-end hotel share -> dummy + centred continuous share
    has_hotel_beds = factor(if_else(total_hotel_beds > 0, "Yes", "No")),
    
    ## physical geography (categorical + log for continuous measures)
    island_municipality = factor(island_municipality, levels = c(0, 1),
                                 labels = c("Mainland", "Island")),
    altitude_zone        = factor(altitude_zone),
    log_sea_coast_km     = log(1 + sea_coast_km),
    log_lake_coast_km    = log(1 + lake_coast_km),
    log_protected_area   = log(1 + protected_areas_sqkm),
    
    ## attractor endowment (log)
    log_museums       = log(1 + museums),
    log_architecture  = log(1 + architectural_features),
    log_sports        = log(1 + sports_facilities),
    log_nature        = log(1 + nature_based),
    log_theme_parks   = log(1 + theme_parks),
    log_nightlife     = log(1 + nightlife),
    
    ## accessibility (log)
    log_transport_pts = log(1 + public_transport_points),
    log_airport_dist  = log(1 + airport_straight_km),
    
    ## UNESCO -> dummy (from the count, NOT from the names field)
    has_unesco = factor(if_else(n_unesco_sites > 0, "Yes", "No"))
  )

high_end_mean <- mean(map_data$high_end_hotel_beds_pct[map_data$has_hotel_beds == "Yes"],
                      na.rm = TRUE)

map_data <- map_data %>%
  mutate(
    high_end_pct_centered = if_else(has_hotel_beds == "Yes",
                                    high_end_hotel_beds_pct - high_end_mean,
                                    0)
  )

## Baseline model formula (population and UNESCO site names excluded by
## design; see comments above for the has_hotel_beds / high_end_pct_
## centered construction)
model_formula <- log_stays ~ log_hotel_beds + log_non_hotel_beds +
  has_hotel_beds + high_end_pct_centered +
  island_municipality + altitude_zone +
  log_sea_coast_km + log_lake_coast_km + log_protected_area +
  log_museums + log_architecture + log_sports + log_nature +
  log_theme_parks + log_nightlife + log_transport_pts +
  log_airport_dist + has_unesco

## Subset of regressors to be spatially lagged (WX) in the SDM/SDEM.
## Only CONTINUOUS regressors are lagged, not the categorical/dummy ones
## (has_hotel_beds, island_municipality, altitude_zone, has_unesco):
## lagging a 0/1 or multi-level dummy through W produces a continuous
## "neighbourhood share" variable, which is a legitimate but different
## modelling choice: with several multi-level factors already in the
## model (altitude_zone has 5 levels), lagging every dummy would greatly
## inflate the number of parameters without a clear substantive gain
## here, so we keep the WX block parsimonious and restricted to the
## continuous endowment/accessibility variables - the natural candidates
## for spatial spillovers.
durbin_formula <- ~ log_hotel_beds + log_non_hotel_beds +
  high_end_pct_centered + log_sea_coast_km + log_lake_coast_km +
  log_protected_area + log_museums + log_architecture + log_sports +
  log_nature + log_theme_parks + log_nightlife + log_transport_pts +
  log_airport_dist

## ------------------------------------------------------------
## 2. SPATIAL WEIGHT MATRIX (queen contiguity, as selected in RQ1)
## ------------------------------------------------------------
## NOTE: the course lab example builds W with dnearneigh() on point
## centroids (dnb420 <- dnearneigh(coords, 0, 420)), which is the
## natural choice when the unit of analysis is a set of points/centroids
## at a coarse (NUTS2-type) scale. Here the unit of analysis is the
## individual municipality polygon, so we keep the contiguity-based W
## selected and validated in RQ1 (queen criterion) rather than switching
## to a distance-band criterion; the two are conceptually interchangeable
## specifications of "closeness" as discussed in the lectures, and the
## choice should in any case be checked for robustness (RQ1, section 7).

nb_queen <- poly2nb(map_data, queen = TRUE)
n_isolated <- sum(card(nb_queen) == 0)
if (n_isolated > 0) {
  coords  <- st_coordinates(st_centroid(st_geometry(map_data)))
  nb_knn1 <- knn2nb(knearneigh(coords, k = 1))
  nb_queen <- union.nb(nb_queen, nb_knn1)
}

## IMPORTANT: knn-based neighbours are not symmetric by construction
## (island A's nearest neighbour may be B, without B's nearest neighbour
## necessarily being A), so after union.nb() the resulting neighbour
## list may no longer be symmetric even though the underlying queen
## criterion is. method = "Matrix" in lagsarlm()/errorsarlm() requires a
## symmetric neighbour structure to build the sparse Cholesky
## factorisation ("Matrix method requires symmetric weights"), so we
## force symmetry by adding any missing reciprocal links.
stopifnot(exists("nb_queen"))
if (!spdep::is.symmetric.nb(nb_queen, verbose = FALSE, force = TRUE)) {
  nb_queen <- make.sym.nb(nb_queen)
}

listw_queen <- nb2listw(nb_queen, style = "W", zero.policy = TRUE)

## ------------------------------------------------------------
## 3. STEP 1 (Elhorst 2010): BASELINE OLS MODEL
## ------------------------------------------------------------

ols_model <- lm(model_formula, data = map_data)
summary(ols_model)
write_csv(tidy(ols_model), "analysis/RQ-2/ols_coefficients.csv")

## --- Collinearity diagnostics ---
## (see the dedicated fix from the previous iteration: high_end_pct_
## centered/has_hotel_beds no longer alias each other; this check is
## kept as a general safeguard for any other term)
alias_check <- alias(ols_model)

if (!is.null(alias_check$Complete)) {
  cat("\n*** ALIASED COEFFICIENTS DETECTED ***\n")
  print(alias_check$Complete)
  mm <- model.matrix(ols_model)
  lin_combos <- caret::findLinearCombos(mm)
  cat("\nColumns of the model matrix involved in the linear dependency:\n")
  print(colnames(mm)[unlist(lin_combos$linearCombos)])
} else {
  print(vif(ols_model, type = "predictor"))
}

## --- Residuals -> map ---
map_data$ols_resid <- residuals(ols_model)

ggplot(map_data) +
  geom_sf(aes(fill = ols_resid), color = "white", linewidth = 0.05) +
  scale_fill_gradient2(low = "#2c7bb6", mid = "white", high = "#d7191c",
                       midpoint = 0, name = "OLS residual") +
  labs(title = "Spatial distribution of OLS residuals",
       subtitle = "log(1+overnight stays) ~ tourism endowment") +
  theme_minimal()
ggsave("analysis/RQ-2/ols_residuals_map.png", width = 9, height = 9, dpi = 200)

## ------------------------------------------------------------
## 4. STEP 1 (cont.): MORAN'S I TEST ON OLS RESIDUALS
## ------------------------------------------------------------

moran_resid <- lm.morantest(ols_model, listw_queen, zero.policy = TRUE,
                            alternative = "greater")
print(moran_resid)

png("analysis/RQ-2/moran_scatterplot_ols_residuals.png",
    width = 1400, height = 1100, res = 150)
moran.plot(map_data$ols_resid, listw_queen, zero.policy = TRUE,
           xlab = "OLS residual",
           ylab = "spatial lag of OLS residual",
           main = "Moran scatterplot - OLS residuals")
dev.off()

## ------------------------------------------------------------
## 5. STEP 1 (cont.): LM / ROBUST LM TESTS  -  lm.RStests()
## ------------------------------------------------------------
## As in the course lab: the LM test makes the alternative hypothesis
## explicit, either in the form of a SAR ("RSlag") or of a SEM
## ("RSerr"), together with their robust versions ("adjRSlag",
## "adjRSerr") which control for the presence of the other type of
## dependence.

lm_tests <- lm.RStests(ols_model, listw_queen,
                       test = c("RSerr", "RSlag", "adjRSerr", "adjRSlag"),
                       zero.policy = TRUE)
summary(lm_tests)

## Extract into a plain data.frame for saving to disk. lm.RStests()
## returns a list of "htest" objects, sometimes nested under $results
## depending on the spatialreg version - handle both robustly.
lm_tests_list <- lm_tests$results
if (is.null(lm_tests_list)) lm_tests_list <- lm_tests
lm_tests_list <- lm_tests_list[sapply(lm_tests_list, inherits, "htest")]

if (length(lm_tests_list) == 0) {
  stop("Could not locate the individual test results inside the object ",
       "returned by lm.RStests() - run str(lm_tests) and adjust the ",
       "extraction above to match the structure shown.")
}

lm_tests_table <- do.call(rbind, lapply(names(lm_tests_list), function(nm) {
  res <- lm_tests_list[[nm]]
  data.frame(test      = nm,
             statistic = unname(res$statistic),
             parameter = unname(res$parameter),
             p_value   = res$p.value)
}))
print(lm_tests_table)
write_csv(lm_tests_table, "analysis/RQ-2/lm_tests_table.csv")

## Elhorst (2010) decision rule, to be read off lm_tests_table:
##  - only RSerr/adjRSerr significant  -> SEM branch
##  - only RSlag/adjRSlag significant  -> SAR branch
##  - both significant                 -> estimate the SDM and use LR
##    tests (step 7 below) to see whether it simplifies to SAR or SEM

## ------------------------------------------------------------
## 6. STEP 2 (Elhorst 2010): ESTIMATION OF THE CANDIDATE MODELS
## ------------------------------------------------------------
## NOTE ON ESTIMATION METHOD: with ~n = 8,000 municipalities, the default
## method = "eigen" is computationally infeasible (full eigendecomposition
## of an n x n matrix at every likelihood iteration). method = "Matrix"
## exploits the sparsity of W via sparse Cholesky/LU factorisation and is
## the method recommended for samples of this size; it does not change
## the model specification, only how the log-determinant is computed.

## --- SDM: y = rho*Wy + X*beta + WX*theta + eps ---
## (Durbin = TRUE in the course lab lags ALL regressors; here we instead
## pass a one-sided formula to Durbin, restricting WX to the continuous
## regressors defined above as `durbin_formula` - see the comment there)
SDM <- lagsarlm(model_formula, data = map_data, listw = listw_queen,
                Durbin = durbin_formula, method = "Matrix",
                zero.policy = TRUE)
summary(SDM)

## --- SAR: y = rho*Wy + X*beta + eps ---
SAR <- lagsarlm(model_formula, data = map_data, listw = listw_queen,
                method = "Matrix", zero.policy = TRUE)
summary(SAR)

## --- SDEM: y = X*beta + WX*theta + u,  u = lambda*Wu + eps ---
SDEM <- errorsarlm(model_formula, data = map_data, listw = listw_queen,
                   Durbin = durbin_formula, method = "Matrix",
                   zero.policy = TRUE)
summary(SDEM)

## --- SEM: y = X*beta + u,  u = lambda*Wu + eps ---
SEM <- errorsarlm(model_formula, data = map_data, listw = listw_queen,
                  method = "Matrix", zero.policy = TRUE)
summary(SEM)

## --- SLX: y = X*beta + WX*theta + eps (OLS with spatially lagged X) ---
SLX <- lmSLX(model_formula, data = map_data, listw = listw_queen,
             Durbin = durbin_formula, zero.policy = TRUE)
summary(SLX)

## ------------------------------------------------------------
## 7. INTERPRETING PARAMETERS AND TESTING FOR SPILLOVERS
## ------------------------------------------------------------
## As in the course lab (Arbia 2014): in SAR/SDM a change in X in
## municipality i affects not only y_i but also y_j in other
## municipalities, so raw coefficients cannot be read as marginal
## effects directly - direct/indirect/total impacts must be computed.
##
## NOTE ON COMPUTATION: impacts() needs the traces of the powers of W
## that appear in the infinite series (I - rho*W)^-1 = sum_q rho^q W^q
## (seen in the lectures). When called as impacts(model, listw = ...),
## it computes these traces EXACTLY (type = "mult"), which does not
## scale to ~8,000 municipalities and is why the previous call hung.
## The fix - directly from LeSage & Pace (2009), the same reference used
## for the impact measures in the lectures - is to estimate the traces
## via their Monte Carlo simulation method (trW(..., type = "MC"))
## instead of computing them exactly, and pass them to impacts() via the
## `tr` argument. This changes only the (approximate, but very accurate
## for a small number of neighbours per unit) trace computation, not the
## definition of direct/indirect/total impacts or the impacts() function
## itself.

set.seed(123)
W_sparse <- as(listw_queen, "CsparseMatrix")
trMC <- trW(W_sparse, type = "MC")

## impacts() draws R simulated coefficient vectors from
## MASS::mvrnorm(R, mu, Sigma = vcov(model)) to obtain simulated standard
## errors/p-values for the direct/indirect/total effects. In an SDM the
## X and WX blocks are often strongly correlated (W acts as a spatial
## smoother), which can make vcov(model) numerically not positive
## definite and causes mvrnorm() to fail ("Sigma non e' definito
## positivo"). The wrapper below tries the simulation first (as in the
## course lab) and, ONLY if it fails for this specific reason, falls
## back to R = NULL: this still returns valid point estimates for the
## direct/indirect/total impacts, just without simulated significance.
safe_impacts <- function(model, tr, R = 100) {
  tryCatch({
    impacts(model, tr = tr, R = R)
  }, error = function(e) {
    if (grepl("not positive definite|non e' definito positivo|non \u00e8 definito positivo",
              conditionMessage(e), ignore.case = TRUE)) {
      warning(
        "vcov(model) is not positive definite - likely strong X/WX ",
        "collinearity in the SDM. Falling back to impacts(..., R = NULL): ",
        "point estimates of direct/indirect/total effects are still valid, ",
        "but simulated significance is not available for this model. ",
        "Consider trimming the variable set in `durbin_formula` if this ",
        "matters for the final report.", call. = FALSE)
      impacts(model, tr = tr, R = NULL)
    } else {
      stop(e)
    }
  })
}

## Summarise, using simulated z-stats only when the simulation succeeded
summarise_impacts <- function(imp, label) {
  cat("\n---", label, "---\n")
  if (!is.null(imp$sres)) {
    summary(imp, zstats = TRUE, short = TRUE)
  } else {
    summary(imp, short = TRUE)
  }
}

impSAR <- safe_impacts(SAR, trMC, R = 100)
summarise_impacts(impSAR, "SAR impacts")

impSDM <- safe_impacts(SDM, trMC, R = 100)
summarise_impacts(impSDM, "SDM impacts")

## Save the point estimates (direct/indirect/total) to disk. These are
## always available in imp$res regardless of whether the simulation for
## standard errors succeeded.
save_impacts <- function(imp, model_name) {
  tab <- as.data.frame(imp$res)
  tab$variable <- rownames(tab)
  tab$model <- model_name
  tab$simulated_se_available <- !is.null(imp$sres)
  tab
}
impacts_table <- rbind(save_impacts(impSAR, "SAR"), save_impacts(impSDM, "SDM"))
write_csv(impacts_table, "analysis/RQ-2/impacts_SAR_SDM.csv")

## ------------------------------------------------------------
## 8. CHOOSING THE PROPER SPECIFICATION  -  anova() LR tests
## ------------------------------------------------------------
## Elhorst (2010) selection strategy (as in the course lab):
##  1. Estimate OLS, test with the LM test whether SAR or SEM is more
##     appropriate (step 5 above).
##  2. If OLS is rejected in favour of SAR, SEM, or both, estimate the
##     SDM.
##  3. Use LR tests to check whether the SDM can be simplified to SAR
##     (H0: theta = 0) and/or to SEM.
##  4. If BOTH restrictions are rejected -> SDM best describes the data.
##  5. If i) cannot be rejected -> SAR is preferred, PROVIDED the
##     (robust) LM test also pointed to SAR.
##  6. If ii) cannot be rejected -> SEM is preferred, PROVIDED the
##     (robust) LM test also pointed to SEM; in that case also estimate
##     the SDEM and check whether the lagged-X coefficients (theta) are
##     jointly significant.

cat("\n--- LR test: SDM vs SAR (H0: theta = 0) ---\n")
lrt_sdm_sar <- anova(SDM, SAR)
print(lrt_sdm_sar)

cat("\n--- LR test: SDM vs SEM ---\n")
lrt_sdm_sem <- anova(SDM, SEM)
print(lrt_sdm_sem)

cat("\n--- LR test: SDEM vs SEM (are the lagged-X coefficients jointly significant?) ---\n")
lrt_sdem_sem <- anova(SDEM, SEM)
print(lrt_sdem_sem)

lrt_table <- rbind(
  data.frame(comparison = "SDM vs SAR",  as.data.frame(lrt_sdm_sar)),
  data.frame(comparison = "SDM vs SEM",  as.data.frame(lrt_sdm_sem)),
  data.frame(comparison = "SDEM vs SEM", as.data.frame(lrt_sdem_sem))
)
write_csv(lrt_table, "analysis/RQ-2/lrt_table.csv")

## Model comparison table (AIC / log-likelihood) across all specifications
model_comparison <- data.frame(
  model  = c("OLS", "SAR", "SEM", "SDM", "SDEM", "SLX"),
  AIC    = c(AIC(ols_model), AIC(SAR), AIC(SEM), AIC(SDM), AIC(SDEM), AIC(SLX)),
  logLik = c(as.numeric(logLik(ols_model)), as.numeric(logLik(SAR)),
             as.numeric(logLik(SEM)), as.numeric(logLik(SDM)),
             as.numeric(logLik(SDEM)), as.numeric(logLik(SLX)))
)
print(model_comparison)
write_csv(model_comparison, "analysis/RQ-2/model_comparison_table.csv")

## ------------------------------------------------------------
## 9. FINAL MODEL SELECTION
## ------------------------------------------------------------
## Apply the decision rule from section 8 using the printed p-values in
## lrt_table.csv and lm_tests_table.csv:
##   - if both anova(SDM,SAR) and anova(SDM,SEM) reject H0 (p < 0.05)
##       -> keep SDM
##   - if anova(SDM,SAR) does NOT reject H0, and the (robust) LM test
##     pointed to SAR -> keep SAR
##   - if anova(SDM,SEM) does NOT reject H0, and the (robust) LM test
##     pointed to SEM -> check anova(SDEM,SEM); if the lagged-X
##     coefficients are jointly significant, prefer SDEM, otherwise SEM
##
## NOTE: the line below is a PLACEHOLDER (set to SAR, the most common
## outcome for tourism-flow models in the cited literature and in the
## Columbus illustration from the lectures). Replace it with the
## specification actually indicated by lrt_table / lm_tests_table once
## computed on the real data.

final_model <- SAR   # <-- update after inspecting lrt_table.csv
final_model_name <- "SAR"

write_csv(tidy(final_model), "analysis/RQ-2/final_model_coefficients.csv")

## ------------------------------------------------------------
## 10. FINAL MODEL RESIDUALS -> MAP
## ------------------------------------------------------------

map_data$final_resid <- residuals(final_model)

ggplot(map_data) +
  geom_sf(aes(fill = final_resid), color = "white", linewidth = 0.05) +
  scale_fill_gradient2(low = "#2c7bb6", mid = "white", high = "#d7191c",
                       midpoint = 0, name = paste(final_model_name, "residual")) +
  labs(title = paste0("Spatial distribution of ", final_model_name, " residuals"),
       subtitle = "log(1+overnight stays) ~ tourism endowment (spatial model)") +
  theme_minimal()
ggsave("analysis/RQ-2/final_model_residuals_map.png", width = 9, height = 9, dpi = 200)

moran_final_resid <- moran.test(map_data$final_resid, listw_queen,
                                zero.policy = TRUE, alternative = "greater")
print(moran_final_resid)

## ------------------------------------------------------------
## 11. SUMMARY OUTPUT
## ------------------------------------------------------------

cat("\n==================== RQ2 SUMMARY ====================\n")
cat("OLS residual Moran's I p-value:", format.pval(moran_resid$p.value), "\n")
cat("LM/robust-LM tests: see analysis/RQ-2/lm_tests_table.csv\n")
cat("Model comparison (AIC): see analysis/RQ-2/model_comparison_table.csv\n")
cat("LR tests (SDM vs SAR/SEM, SDEM vs SEM): see analysis/RQ-2/lrt_table.csv\n")
cat("Direct/indirect/total impacts (SAR, SDM): see analysis/RQ-2/impacts_SAR_SDM.csv\n")
cat("Selected specification:", final_model_name, "\n")
cat("Residual Moran's I of selected model p-value:",
    format.pval(moran_final_resid$p.value), "\n")
cat("=======================================================\n")