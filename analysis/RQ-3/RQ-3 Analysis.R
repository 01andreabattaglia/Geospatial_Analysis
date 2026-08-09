library(sf)
library(spdep)
library(spatialreg)
library(dplyr)
library(readr)
library(ggplot2)
library(stringr)
library(broom)

## 1. IMPORT AND MERGE ------------------------------------------------

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

## 2. VARIABLE CONSTRUCTION --------------------------------------------

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

if (any(!map_data$COD_RIP %in% 1:5) || length(unique(map_data$macro_area)) < 2) {
  warning(
    "Unexpected COD_RIP values or macro_area collapsed to a single ",
    "category. Inspect sort(unique(map_data$COD_RIP)) and adjust the ",
    "case_when() mapping above if this shapefile release codes ",
    "COD_RIP differently.",
    call. = FALSE
  )
}

## 3. SPATIAL WEIGHT MATRIX W (queen contiguity) -----------------------

build_listw <- function(data) {
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

## 4. FINAL MODEL (outcome of the selection performed in RQ2) ----------

final_model_name <- "SAR"   # align with RQ2 (SAR / SEM / SDM / SDEM)

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

## 5. DIRECT/INDIRECT/TOTAL IMPACTS (LeSage & Pace 2009) ----------------

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

## Sign of the indirect effect (spillover):
##   indirect > 0 and significant -> complementarity/agglomeration
##   indirect < 0 and significant -> substitution/competition
##   not significant               -> no evidence of spillover
build_impacts_table <- function(imp, alpha = 0.05) {
  res <- imp$res
  direct   <- as.numeric(res$direct)
  indirect <- as.numeric(res$indirect)
  total    <- as.numeric(res$total)
  
  lens <- c(direct = length(direct), indirect = length(indirect), total = length(total))
  if (length(unique(lens)) > 1) {
    stop(sprintf(
      paste("impacts() returned mismatched vector lengths",
            "(direct = %d, indirect = %d, total = %d): the model fit",
            "on this subsample is too degenerate to build an impacts",
            "table."),
      lens["direct"], lens["indirect"], lens["total"]
    ), call. = FALSE)
  }
  
  ## Variable names come from the top-level "bnames" attribute, as in
  ## RQ2's impacts_to_table(): res$direct is unnamed for a SAR model,
  ## so relying on names(res$direct) or sres colnames is unreliable.
  var_names <- attr(imp, "bnames")
  if (is.null(var_names) || length(var_names) != length(direct)) {
    stop("Could not recover variable names from impacts()'s 'bnames' ",
         "attribute; the model fit on this subsample is too degenerate ",
         "to build an impacts table.", call. = FALSE)
  }
  
  tab <- data.frame(
    variable = var_names,
    direct   = direct,
    indirect = indirect,
    total    = total
  )
  
  if (!is.null(imp$sres)) {
    ind_draws <- as.matrix(imp$sres$indirect)
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
impacts_table

## 6. TERRITORIAL BREAKDOWN OF SPILLOVERS --------------------------------
## Re-estimates the final model on each subsample (coast/mountain/plain;
## North/Centre/South-Islands), with W rebuilt on the subsample itself.
## Caveat: truncating the sample breaks the neighbour structure at the
## group's edges, so this is a descriptive/exploratory breakdown rather
## than a true multi-group spatial interaction; a more robust check
## would use a model with X*macro_area interaction terms estimated on
## the full sample with the full W.

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
  vars <- all.vars(formula)[-1]
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
impacts_by_coast

impacts_by_macroarea <- fit_impacts_by_group(map_data, "macro_area")
impacts_by_macroarea

## 7. MAP OF THE INDIRECT IMPACT AROUND A SELECTED MUNICIPALITY ---------
## Supporting visualisation for the interactive map (project section
## 3.4): highlights the neighbours (per W) of a chosen municipality.

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
