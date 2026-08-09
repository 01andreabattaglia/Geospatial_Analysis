## ============================================================
## RQ3 - Are there spatial spillovers between neighbouring
##       municipalities, and are they complementary or competitive?
##
## Builds on the structure and choices of 4_Spatial_regression_models.R
## (same import/merge, same variable construction, same queen W, same
## safe_impacts()/trW(type="MC") trick used there for large n).
## Adds:
##   - a direct/indirect/total impacts table with sign interpretation
##     (complementarity vs competition, cf. Yang & Wong 2012;
##     Arena et al. 2026)
##   - a territorial breakdown (coast/mountain/plain; North/Centre/
##     South) via re-estimation of the final model on subsamples,
##     with W rebuilt on each subsample
##
## FIX 1: fit_impacts_by_group() now drops any predictor that becomes
## constant / collapses to a single factor level within a given
## territorial subsample (e.g. island_municipality inside the
## "Island" subgroup) before re-estimating the model there. Without
## this, lagsarlm()/errorsarlm() fails with:
##   "i contrasti si possono applicare solo a variabili factor con 2
##    o più livelli" ("contrasts can be applied only to factors with
##    2 or more levels")
## because a factor that is literally constant within the subsample
## can't get contrasts built for it.
##
## FIX 2 (this version): fit_impacts_by_group() no longer calls
## droplevels() directly on the sf subsample. `sub` is still an sf
## object at that point (it carries the geometry list-column, class
## sfc/sfc_GEOMETRY). droplevels.data.frame() tries to apply
## droplevels() to *every* column, including the geometry column, and
## there is no droplevels() method for class sfc_GEOMETRY/sfc, which
## produced:
##   "Errore in UseMethod("droplevels"): su un oggetto di classe
##    'sfc_GEOMETRY', 'sfc' è stato usato un metodo non applicabile"
## Fixed with drop_unused_levels_sf(), a small wrapper that drops
## unused levels only on the actual factor columns and explicitly
## skips the sf geometry column, preserving the original intent
## (clear out stray factor levels left over from the full dataset
## before checking/dropping constant predictors) without touching the
## geometry.
##
## FIX 3 (this version): safe_impacts() no longer decides whether to
## fall back to R = NULL by grepl()-ing the English string "not
## positive definite" out of the error message. Under a non-English R
## session (e.g. Italian) the equivalent mvrnorm() failure reads
## "'Sigma' non è definito positivo", the English-only pattern never
## matched, and the intended graceful fallback instead re-raised the
## error and stopped the script (seen when fitting fragmented
## territorial subsamples, whose ill-conditioned Hessian - flagged by
## the accompanying "NaN" warning from sqrt(diag(fdHess)[-1]) -
## produces a non-positive-definite covariance for the simulation
## step). safe_impacts() now falls back to R = NULL on *any* error
## raised while requesting simulated impacts, independent of locale
## or exact message wording.
## ============================================================
## Required packages:
##   install.packages(c("sf", "spdep", "spatialreg", "dplyr", "readr",
##                       "ggplot2", "stringr", "broom"))
## ============================================================

library(sf)
library(spdep)
library(spatialreg)
library(dplyr)
library(readr)
library(ggplot2)
library(stringr)
library(broom)

dir.create("analysis/RQ-3", recursive = TRUE, showWarnings = FALSE)

## ------------------------------------------------------------
## 0. DATA IMPORT + MERGE (identical to RQ1/RQ2)
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

cat("Municipalities used in the RQ3 analysis:", nrow(map_data), "\n")

## ------------------------------------------------------------
## 1. VARIABLE CONSTRUCTION (same as RQ2)
## ------------------------------------------------------------

map_data <- map_data %>%
  mutate(
    log_stays = log(1 + total_overnight_stays),
    
    log_hotel_beds     = log(1 + total_hotel_beds),
    log_non_hotel_beds = log(1 + total_non_hotel_beds),
    has_hotel_beds      = factor(if_else(total_hotel_beds > 0, "Yes", "No")),
    
    island_municipality = factor(island_municipality, levels = c(0, 1),
                                 labels = c("Mainland", "Island")),
    altitude_zone        = factor(altitude_zone),
    log_sea_coast_km     = log(1 + sea_coast_km),
    log_lake_coast_km    = log(1 + lake_coast_km),
    log_protected_area   = log(1 + protected_areas_sqkm),
    
    log_museums       = log(1 + museums),
    log_architecture  = log(1 + architectural_features),
    log_sports        = log(1 + sports_facilities),
    log_nature        = log(1 + nature_based),
    log_theme_parks   = log(1 + theme_parks),
    log_nightlife     = log(1 + nightlife),
    
    log_transport_pts = log(1 + public_transport_points),
    log_airport_dist  = log(1 + airport_straight_km),
    
    has_unesco = factor(if_else(n_unesco_sites > 0, "Yes", "No"))
  )

high_end_mean <- mean(map_data$high_end_hotel_beds_pct[map_data$has_hotel_beds == "Yes"],
                      na.rm = TRUE)
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

durbin_formula <- ~ log_hotel_beds + log_non_hotel_beds +
  high_end_pct_centered + log_sea_coast_km + log_lake_coast_km +
  log_protected_area + log_museums + log_architecture + log_sports +
  log_nature + log_theme_parks + log_nightlife + log_transport_pts +
  log_airport_dist

## Territorial grouping needed for the RQ3 breakdown:
## - coast / mountain / plain, derived from island_municipality,
##   sea_coast_km/lake_coast_km and altitude_zone (labels to be
##   adapted to the actual values of altitude_zone in the dataset)
## - North / Centre / South-Islands, derived from COD_RIP, the
##   official ISTAT "ripartizione geografica" code already present in
##   the boundary shapefile:
##     1 = North-West, 2 = North-East, 3 = Centre, 4 = South, 5 = Islands
##   (see ISTAT's "Codici statistici delle unita' amministrative"
##   documentation). This is more robust than matching on region-name
##   strings, which vary across shapefile releases/encodings.
stopifnot("COD_RIP" %in% names(map_data))

map_data <- map_data %>%
  mutate(
    coast_type = case_when(
      island_municipality == "Island" ~ "Island",
      sea_coast_km > 0 | lake_coast_km > 0 ~ "Coast/Lake",
      altitude_zone %in% c("Inland mountain", "Coastal mountain") ~ "Mountain",
      TRUE ~ "Plain/Inland"
    ),
    macro_area = case_when(
      COD_RIP %in% c(1, 2) ~ "North",
      COD_RIP == 3         ~ "Centre",
      COD_RIP %in% c(4, 5) ~ "South and Islands",
      TRUE                 ~ NA_character_
    )
  )

## Sanity check: COD_RIP should only take values 1-5; anything else
## (or a collapsed macro_area) signals the field does not follow the
## standard ISTAT coding in this shapefile release - inspect with:
##   sort(unique(map_data$COD_RIP))
if (any(!map_data$COD_RIP %in% 1:5) || length(unique(map_data$macro_area)) < 2) {
  warning(
    "Unexpected COD_RIP values or macro_area collapsed to a single ",
    "category. Inspect sort(unique(map_data$COD_RIP)) and adjust the ",
    "case_when() mapping above if this shapefile release codes ",
    "COD_RIP differently.",
    call. = FALSE
  )
}

## ------------------------------------------------------------
## 2. SPATIAL WEIGHT MATRIX W (queen, as selected in RQ1/RQ2)
## ------------------------------------------------------------

build_listw <- function(data) {
  ## Reset row names to a plain 1..n sequence before building any
  ## neighbour object. poly2nb() tags its neighbour list with
  ## region.id = row.names(data), while knn2nb(knearneigh(...)) always
  ## numbers observations 1..n; on a filtered subset (as used in the
  ## group-wise re-estimation below) the original row names are NOT
  ## 1..n, so the two neighbour lists disagree on IDs and union.nb()
  ## fails with "Both neighbor objects must be generated from the same
  ## coordinates". Resetting row names here makes the IDs consistent
  ## regardless of whether `data` is the full dataset or a subset.
  row.names(data) <- as.character(seq_len(nrow(data)))
  
  nb <- poly2nb(data, queen = TRUE)
  n_isolated <- sum(card(nb) == 0)
  if (n_isolated > 0) {
    coords  <- st_coordinates(st_centroid(st_geometry(data)))
    nb_knn1 <- knn2nb(knearneigh(coords, k = 1))
    nb <- union.nb(nb, nb_knn1)
  }
  if (!spdep::is.symmetric.nb(nb, verbose = FALSE, force = TRUE)) {
    nb <- make.sym.nb(nb)
  }
  nb2listw(nb, style = "W", zero.policy = TRUE)
}

listw_queen <- build_listw(map_data)

## ------------------------------------------------------------
## 3. FINAL MODEL (outcome of the selection performed in RQ2:
##    Elhorst 2010 - LM/RLM tests + LR test SDM vs SAR/SEM)
## ------------------------------------------------------------
## NOTE: replace "SAR" with the specification actually indicated by
## analysis/RQ-2/lrt_table.csv and analysis/RQ-2/lm_tests_table.csv.
## The model is re-estimated here so that the RQ3 script is
## self-contained (it does not depend on RQ2's in-memory objects).

final_model_name <- "SAR"   # <-- align with RQ2 (SAR / SEM / SDM / SDEM)

final_model <- switch(final_model_name,
                      SAR  = lagsarlm(model_formula, data = map_data, listw = listw_queen,
                                      method = "Matrix", zero.policy = TRUE),
                      SDM  = lagsarlm(model_formula, data = map_data, listw = listw_queen,
                                      Durbin = durbin_formula, method = "Matrix", zero.policy = TRUE),
                      SEM  = errorsarlm(model_formula, data = map_data, listw = listw_queen,
                                        method = "Matrix", zero.policy = TRUE),
                      SDEM = errorsarlm(model_formula, data = map_data, listw = listw_queen,
                                        Durbin = durbin_formula, method = "Matrix", zero.policy = TRUE),
                      stop("final_model_name must be one of SAR/SDM/SEM/SDEM")
)
summary(final_model)

## ------------------------------------------------------------
## 4. DIRECT/INDIRECT/TOTAL IMPACTS (LeSage & Pace 2009)
## ------------------------------------------------------------
## Same strategy as RQ2: the trace of the powers of W is approximated
## via Monte Carlo simulation (trW type = "MC"), with a fallback to
## R = NULL if the simulation step fails (typically because vcov(model)
## / the fdHess-based covariance is not positive definite, which shows
## up as an mvrnorm() error on 'Sigma').
##
## FIX 3: the previous version tried to detect this specific failure
## by grepl()-ing the English string "not positive definite" out of
## the error message. That only works if R is running under an
## English locale. Under an Italian session the same underlying
## mvrnorm() failure raises "'Sigma' non è definito positivo" instead,
## the grepl() didn't match, and the handler fell through to stop(e),
## turning what was meant to be a graceful fallback into a fatal
## error (as seen with fit_impacts_by_group() on the "Coast/Lake" or
## similar fragmented subsamples, where poly2nb()/union.nb() report
## many disconnected sub-graphs and the resulting Hessian is
## ill-conditioned - hence also the "NaN" warning from
## sqrt(diag(fdHess)[-1]) immediately before the crash).
## Fixed by no longer inspecting the error message at all: any error
## raised specifically while requesting the *simulated* impacts
## (R = R) is treated as a signal to fall back to point estimates
## only (R = NULL), regardless of locale or exact wording. Genuine
## upstream problems (bad formula, singular design matrix, etc.) will
## already have surfaced earlier, when fitting mod_sub itself.
safe_impacts <- function(model, tr, R = 100) {
  tryCatch({
    impacts(model, tr = tr, R = R)
  }, error = function(e) {
    warning("impacts() simulation failed (", conditionMessage(e), "): ",
            "falling back to R = NULL (point estimates only, no ",
            "simulated significance for the indirect effects).",
            call. = FALSE)
    impacts(model, tr = tr, R = NULL)
  })
}

set.seed(123)
W_sparse <- as(listw_queen, "CsparseMatrix")
trMC <- trW(W_sparse, type = "MC")

imp_final <- safe_impacts(final_model, trMC, R = 100)

## Direct/indirect/total table with interpretation of the sign of the
## indirect effect (spillover):
##   indirect > 0 and significant -> complementarity/agglomeration
##   indirect < 0 and significant -> substitution/competition
##   not significant               -> no evidence of spillover
##
## NOTE: this deliberately does NOT rely on summary.lagImpact()'s
## internal field names (e.g. $direct_sum), which have changed across
## spatialreg versions and caused "numero di dimensioni errato" /
## "wrong number of dimensions" here. Instead it reads the point
## estimates straight from imp$res (always present) and, when
## available, computes indirect-effect significance directly from the
## simulated draws in imp$sres (mean/sd of the R simulated indirect
## coefficients -> z-stat -> two-sided p-value), which is the same
## quantity summary(imp, zstats = TRUE) reports internally.
build_impacts_table <- function(imp, alpha = 0.05) {
  res <- imp$res
  direct   <- as.numeric(res$direct)
  indirect <- as.numeric(res$indirect)
  total    <- as.numeric(res$total)
  
  ## FIX 4: on small/near-degenerate subsamples (e.g. after
  ## drop_constant_terms() has stripped most predictors, combined with
  ## a fragmented W) impacts() can return direct/indirect/total
  ## vectors of DIFFERENT lengths from one another (observed: direct
  ## length 1, indirect length 0). data.frame() then fails with the
  ## opaque "arguments imply differing number of rows" error, which
  ## gives no hint about which group or why. Turn that into an
  ## explicit, informative error here; fit_impacts_by_group() catches
  ## it and skips just this group instead of stopping the whole loop.
  lens <- c(direct = length(direct), indirect = length(indirect), total = length(total))
  if (length(unique(lens)) > 1) {
    stop(sprintf(
      paste("impacts() returned mismatched vector lengths",
            "(direct = %d, indirect = %d, total = %d): the model fit",
            "on this subsample is too degenerate to build an impacts",
            "table (likely too few predictors survived",
            "drop_constant_terms(), or too fragmented a W)."),
      lens["direct"], lens["indirect"], lens["total"]
    ), call. = FALSE)
  }
  
  ## Variable-name fallback chain: named vector -> colnames of the
  ## simulated-draws matrix (imp$sres$direct) -> generic var1..varN.
  ## Whatever is used, its length is forced to match length(direct) so
  ## data.frame() below can never fail on a row-count mismatch.
  var_names <- names(res$direct)
  if (is.null(var_names) && !is.null(imp$sres) && !is.null(imp$sres$direct)) {
    var_names <- colnames(imp$sres$direct)
  }
  if (is.null(var_names) || length(var_names) != length(direct)) {
    var_names <- paste0("var", seq_along(direct))
    warning(
      "Could not recover variable names from impacts()'s output; using ",
      "generic var1..varN labels instead. To map these back to the ",
      "actual regressors, compare the order against ",
      "names(coef(final_model)) (excluding the intercept and rho/lambda).",
      call. = FALSE
    )
  }
  
  tab <- data.frame(
    variable = var_names,
    direct   = direct,
    indirect = indirect,
    total    = total
  )
  
  if (!is.null(imp$sres)) {
    ind_draws <- as.matrix(imp$sres$indirect)   # R simulated draws x n. variables
    ind_mean  <- colMeans(ind_draws)
    ind_sd    <- apply(ind_draws, 2, sd)
    z_indirect <- ind_mean / ind_sd
    tab$p_indirect <- 2 * (1 - pnorm(abs(z_indirect)))
  } else {
    tab$p_indirect <- NA_real_
  }
  
  tab$interpretation <- case_when(
    is.na(tab$p_indirect) | tab$p_indirect >= alpha ~ "No significant spillover",
    tab$indirect > 0 ~ "Complementarity / agglomeration",
    tab$indirect < 0 ~ "Substitution / competition"
  )
  tab
}

impacts_table <- build_impacts_table(imp_final)
print(impacts_table)
write_csv(impacts_table, "analysis/RQ-3/impacts_table.csv")

## ------------------------------------------------------------
## 5. TERRITORIAL BREAKDOWN OF SPILLOVERS
## ------------------------------------------------------------
## Re-estimates the final model on each subsample (coast/mountain/
## plain; North/Centre/South-Islands), with W rebuilt on the
## subsample itself.
## METHODOLOGICAL CAVEAT to flag in the conclusions: truncating the
## sample breaks the neighbour structure at the group's edges (border
## municipalities lose neighbours belonging to the other group), so
## this is a descriptive/exploratory breakdown rather than a true
## multi-group spatial interaction; a more robust check would use a
## model with X*macro_area interaction terms estimated on the full
## sample with the full W.
##
## FIX 1: a territorial subsample can make a predictor constant (most
## obviously island_municipality inside the "Island" subgroup, but
## potentially also altitude_zone, has_hotel_beds or has_unesco in
## smaller groups). lagsarlm()/errorsarlm() cannot build contrasts for
## a factor with a single observed level, and fails with:
##   "i contrasti si possono applicare solo a variabili factor con 2
##    o più livelli"
## drop_constant_terms() inspects the subsample and strips out any
## regressor that is constant (numeric) or has collapsed to <2 levels
## (factor) before fitting, and warns which ones were dropped so this
## can be reported alongside the breakdown tables (subsamples are then
## not perfectly comparable variable-for-variable - see caveat above).
##
## FIX 2: `sub` is an sf object (it still carries the geometry
## list-column at the point levels need dropping). Calling the plain
## droplevels() on it fails because droplevels.data.frame() tries to
## call droplevels() on every column, including the geometry column
## (class sfc/sfc_GEOMETRY), for which there is no droplevels()
## method:
##   "Errore in UseMethod("droplevels"): su un oggetto di classe
##    'sfc_GEOMETRY', 'sfc' è stato usato un metodo non applicabile"
## drop_unused_levels_sf() replicates droplevels()'s effect (drop
## unused factor levels left over from the full dataset) but only on
## genuine factor columns, explicitly skipping the sf geometry column
## so it works safely on sf subsamples.

drop_unused_levels_sf <- function(data) {
  geom_col <- attr(data, "sf_column")
  for (col in names(data)) {
    if (identical(col, geom_col)) next
    if (is.factor(data[[col]])) {
      data[[col]] <- droplevels(data[[col]])
    }
  }
  data
}

drop_constant_terms <- function(formula, data) {
  vars <- all.vars(formula)[-1]  # drop the response (log_stays)
  drop_vars <- character(0)
  for (v in vars) {
    if (!v %in% names(data)) next
    col <- data[[v]]
    if (is.factor(col)) {
      if (nlevels(droplevels(col)) < 2) drop_vars <- c(drop_vars, v)
    } else if (is.numeric(col)) {
      if (length(unique(col[!is.na(col)])) < 2) drop_vars <- c(drop_vars, v)
    }
  }
  if (length(drop_vars) > 0) {
    warning("Dropping constant/single-level predictor(s) in this subsample: ",
            paste(drop_vars, collapse = ", "), call. = FALSE)
    formula <- update(formula, paste(". ~ . -", paste(drop_vars, collapse = " - ")))
  }
  formula
}

## FIX 4 (structural): fitting a spatial model on a small, possibly
## territorially-fragmented subsample is inherently numerically
## fragile - island/singleton neighbour structures, disconnected
## sub-graphs, ill-conditioned Hessians, and (as a further
## consequence) degenerate impacts() output are all different
## symptoms of the same root cause, and new variants of it can appear
## on any given group. Rather than special-casing each failure mode
## one at a time, the entire per-group pipeline (level-dropping,
## constant-term-dropping, W construction, model fitting, impacts
## simulation, and table construction) is now wrapped in a single
## tryCatch. Any failure at any stage causes that ONE group to be
## skipped, with a warning naming the group and the underlying error,
## while every other group still gets fitted and reported. This
## replaces the previous behaviour where a single problematic group
## (e.g. one with too little variation left after dropping constant
## predictors) aborted the whole coast_type/macro_area breakdown.
fit_impacts_by_group <- function(data, group_var, min_n = 50) {
  groups <- unique(data[[group_var]])
  out <- lapply(groups, function(g) {
    sub <- data[data[[group_var]] == g, ]
    if (nrow(sub) < min_n) {
      warning(sprintf("Group '%s' excluded: only %d municipalities (< %d).",
                      g, nrow(sub), min_n), call. = FALSE)
      return(NULL)
    }
    
    tab_sub <- tryCatch({
      ## Drop unused factor levels left over from the full dataset
      ## (sf-safe: skips the geometry column), then drop any predictor
      ## that is constant/single-level within `sub`.
      sub <- drop_unused_levels_sf(sub)
      formula_sub <- drop_constant_terms(model_formula, sub)
      durbin_sub  <- if (final_model_name %in% c("SDM", "SDEM")) {
        drop_constant_terms(durbin_formula, sub)
      } else {
        NULL
      }
      
      lw_sub <- build_listw(sub)
      mod_sub <- switch(final_model_name,
                        SAR  = lagsarlm(formula_sub, data = sub, listw = lw_sub,
                                        method = "Matrix", zero.policy = TRUE),
                        SDM  = lagsarlm(formula_sub, data = sub, listw = lw_sub,
                                        Durbin = durbin_sub, method = "Matrix", zero.policy = TRUE),
                        SEM  = errorsarlm(formula_sub, data = sub, listw = lw_sub,
                                          method = "Matrix", zero.policy = TRUE),
                        SDEM = errorsarlm(formula_sub, data = sub, listw = lw_sub,
                                          Durbin = durbin_sub, method = "Matrix", zero.policy = TRUE)
      )
      tr_sub <- trW(as(lw_sub, "CsparseMatrix"), type = "MC")
      imp_sub <- safe_impacts(mod_sub, tr_sub, R = 100)
      tab <- build_impacts_table(imp_sub)
      tab$group <- g
      tab
    }, error = function(e) {
      warning(sprintf(
        "Group '%s' excluded: model/impacts fitting failed (%s).",
        g, conditionMessage(e)
      ), call. = FALSE)
      NULL
    })
    
    tab_sub
  })
  out <- out[!sapply(out, is.null)]
  if (length(out) == 0) {
    warning("No group produced a valid impacts table for '", group_var,
            "'; returning NULL. Inspect the warnings above for the ",
            "reason each group was excluded.", call. = FALSE)
    return(NULL)
  }
  do.call(rbind, out)
}

impacts_by_coast <- fit_impacts_by_group(map_data, "coast_type")
if (!is.null(impacts_by_coast)) {
  write_csv(impacts_by_coast, "analysis/RQ-3/impacts_by_coast_type.csv")
} else {
  warning("Skipping write of impacts_by_coast_type.csv: no group succeeded.",
          call. = FALSE)
}

impacts_by_macroarea <- fit_impacts_by_group(map_data, "macro_area")
if (!is.null(impacts_by_macroarea)) {
  write_csv(impacts_by_macroarea, "analysis/RQ-3/impacts_by_macro_area.csv")
} else {
  warning("Skipping write of impacts_by_macro_area.csv: no group succeeded.",
          call. = FALSE)
}

## ------------------------------------------------------------
## 6. MAP OF THE INDIRECT IMPACT AROUND A SELECTED MUNICIPALITY
## ------------------------------------------------------------
## Supporting visualisation for the interactive map (project section
## 3.4): highlights the neighbours (per W) of a chosen municipality,
## as a basis for shading the spillover in the web app.

highlight_neighbours <- function(data, listw, municipality_name, var = "log_museums") {
  idx <- which(data$municipality_name == municipality_name)
  if (length(idx) == 0) stop("Municipality not found: ", municipality_name)
  idx <- idx[1]
  nb_ids <- listw$neighbours[[idx]]
  data$highlight <- "Other municipalities"
  data$highlight[idx] <- "Selected municipality"
  data$highlight[nb_ids] <- "Neighbour (W)"
  data
}

# Example (adapt to a municipality actually present in the dataset):
# example_map <- highlight_neighbours(map_data, listw_queen, "Example Municipality")
# ggplot(example_map) +
#   geom_sf(aes(fill = highlight), color = "white", linewidth = 0.05) +
#   scale_fill_manual(values = c("Selected municipality" = "#d7191c",
#                                "Neighbour (W)" = "#fdae61",
#                                "Other municipalities" = "grey90")) +
#   theme_minimal()
# ggsave("analysis/RQ-3/example_neighbours_map.png", width = 8, height = 8, dpi = 200)

## ------------------------------------------------------------
## 7. SUMMARY OUTPUT
## ------------------------------------------------------------

cat("\n==================== RQ3 SUMMARY ====================\n")
cat("Final model used for the impacts:", final_model_name, "\n")
cat("Direct/indirect/total impacts table: analysis/RQ-3/impacts_table.csv\n")
cat("Variables with positive spillover (complementarity):\n")
print(impacts_table$variable[impacts_table$interpretation == "Complementarity / agglomeration"])
cat("Variables with negative spillover (competition):\n")
print(impacts_table$variable[impacts_table$interpretation == "Substitution / competition"])
if (!is.null(impacts_by_coast)) {
  cat("Coast/mountain/plain breakdown: analysis/RQ-3/impacts_by_coast_type.csv\n")
} else {
  cat("Coast/mountain/plain breakdown: NOT written (no group succeeded - see warnings above)\n")
}
if (!is.null(impacts_by_macroarea)) {
  cat("North/Centre/South-Islands breakdown: analysis/RQ-3/impacts_by_macro_area.csv\n")
} else {
  cat("North/Centre/South-Islands breakdown: NOT written (no group succeeded - see warnings above)\n")
}
cat("=======================================================\n")
