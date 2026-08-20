# ============================================================
# Interactive spillover map for RQ3 — v3 (English, revised)
# Shiny + Leaflet
#
# CHANGES IN THIS VERSION vs the previous one:
#
#   TAB 1 "Night stays"   - Removed sidebar details table; all values
#                            now appear exclusively in the map popup.
#                          - Altitude zone now displays descriptive labels
#                            (e.g., "Inland hill areas") instead of codes.
#
#   TAB 2 "Spillover"     - SIMPLIFIED sidebar: only the Durbin
#                            variable selector and the spillover-sign
#                            filter remain.
#
#   TAB 3 "What-if"       - REWORKED: slider in natural units, shows
#                            changes for all municipalities, ranks by
#                            percent change.
#
# METHODOLOGICAL NOTE on the "What-if" tab:
#   The model is a spatial Durbin model (SAR + Durbin):
#     log_stays = rho * W * log_stays + X*beta + WX*theta + eps
#   In reduced form:
#     log_stays_hat = (I - rho*W)^-1 * (X*beta + WX*theta)
#   Changing variable v in municipality m produces:
#     (a) a direct effect beta_v on row m (the X*beta term)
#     (b) an effect theta_v on EVERY neighbour j of m, because WX_j
#         includes x_m (the WX*theta term)
#     (c) both shocks then propagate through the whole network via
#         the global operator (I - rho*W)^-1.
#   To avoid paying for an ~n x n factorization on every slider move,
#   the LU factorization of (I - rho*W) is computed ONCE at startup
#   (section 8); every slider move is then a cheap triangular solve.
# ============================================================

library(sf)
library(spdep)
library(spatialreg)
library(Matrix)
library(dplyr)
library(readr)
library(stringr)
library(tidyr)
library(shiny)
library(leaflet)

## 1. DATA IMPORT AND MERGE ---------------------------------------------
df <- read_csv("../data/tourism_final_dataset.csv",
               col_types = cols(province_code = col_character(),
                                municipality_id = col_character())) %>%
  mutate(municipality_id = str_pad(municipality_id, 6, pad = "0"))

comuni_sf <- st_read("../data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp", quiet = TRUE) %>%
  mutate(municipality_id = str_pad(as.character(PRO_COM), 6, pad = "0"))

map_data <- comuni_sf %>%
  inner_join(df, by = "municipality_id") %>%
  filter(!st_is_empty(geometry)) %>%
  st_make_valid()
# IMPORTANT: no st_transform() here. The canonical RQ3 script fits
# poly2nb()/lagsarlm() on the shapefile's native CRS (EPSG:32632,
# despite the "_WGS84" filename). Reprojection is not exact at
# floating-point level - it can silently break or create shared-vertex
# touches between adjacent polygons, changing nb_queen/listw_queen and
# therefore the SDM's Hessian (this is what caused the NaN warning
# that RQ3 itself does not produce).
# WGS84 (4326) reprojection for Leaflet is applied further down, AFTER
# the model is fit, to a render-only copy - see section 7b.

## 2. HANDLE MUNICIPALITY NAME FOR POPUPS -------------------------------
if ("municipality_name" %in% names(map_data)) {
  map_data <- map_data %>% select(-municipality_name)
}

name_col <- intersect(c("COMUNE", "NAME", "NOME", "COMUNE_NAME"), names(map_data))
if (length(name_col) > 0) {
  map_data <- map_data %>% rename(municipality_name = !!sym(name_col[1]))
} else {
  map_data <- map_data %>% mutate(municipality_name = municipality_id)
}

## 3. VARIABLE CONSTRUCTION ----------------------------------------------
# Define altitude zone labels
altitude_labels <- c(
  "1" = "Inland mountain areas",
  "2" = "Coastal mountain areas",
  "3" = "Inland hill areas",
  "4" = "Coastal hill areas",
  "5" = "Plain areas"
)

map_data <- map_data %>%
  mutate(
    log_stays = log(1 + total_overnight_stays),
    log_hotel_beds = log(1 + total_hotel_beds),
    log_non_hotel_beds = log(1 + total_non_hotel_beds),
    island_municipality = factor(island_municipality, levels = c(0, 1),
                                 labels = c("Mainland", "Island")),
    altitude_zone = factor(altitude_zone, levels = 1:5, labels = altitude_labels),
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

# Keep the PRE-scaling values of these variables (still on the log
# scale, but not standardized). Tab 3 ("What-if") uses these so the
# slider can be expressed in real, interpretable units instead of a
# standardized-deviation multiplier. Row order is preserved end-to-end
# (see the notes in sections 7b and 8), so this stays aligned with
# every other row-indexed object built later (nb_queen, X_base, etc).
raw_scale_vars <- map_data %>% st_drop_geometry() %>% select(all_of(scale_vars))

# Mean/sd actually used by scale() below, kept so we can convert a
# raw (log-scale) target value chosen on the What-if slider back into
# the standardized units the model was fit on, and vice versa.
scale_params <- lapply(scale_vars, function(v) {
  x <- raw_scale_vars[[v]]
  list(mean = mean(x, na.rm = TRUE), sd = sd(x, na.rm = TRUE))
})
names(scale_params) <- scale_vars

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

## 4. SPATIAL WEIGHTS MATRIX ---------------------------------------------
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

## 5. FIT THE SAME SDM AS IN RQ2 -----------------------------------------
SDM <- lagsarlm(model_formula, data = map_data, listw = listw_queen,
                Durbin = durbin_formula, method = "Matrix",
                zero.policy = TRUE)

## 6. DIRECT / INDIRECT / TOTAL IMPACTS -----------------------------------
# IMPORTANT: this block is kept IDENTICAL to the canonical RQ3 script
# (trW type, seed, R, and the safe_impacts fallback logic) so the
# impacts table - and therefore every p-value/spillover-type shown in
# the app - matches the published RQ3 results exactly. Do not
# "improve" this in isolation; if trExact/deterministic tracing is
# wanted, it needs to be changed in the canonical RQ3 script too, and
# results re-validated there.
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

## 7. CREATE SPILLOVER VARIABLES AND PER-VARIABLE COLOR DOMAINS -----------
spill_vars <- all.vars(durbin_formula)

map_data_spill <- map_data

for (v in spill_vars) {
  wx_name <- paste0("wx_", v)
  spill_name <- paste0("spill_", v)
  theta_name <- names(SDM$coefficients)[grepl(paste0("^lag\\.", v, "$"), names(SDM$coefficients))]
  theta <- unname(SDM$coefficients[theta_name])
  
  map_data_spill[[wx_name]] <- lag.listw(listw_queen, map_data_spill[[v]], zero.policy = TRUE)
  map_data_spill[[spill_name]] <- theta * map_data_spill[[wx_name]]
}

# Attach the pre-scaling (raw log-scale) values too, for tab 3. Row
# order matches map_data / map_data_spill throughout (see notes in
# 7b and 8), so a plain positional attach is safe.
for (v in scale_vars) {
  map_data_spill[[paste0("raw_", v)]] <- raw_scale_vars[[v]]
}

## 7b. REPROJECT + SIMPLIFY GEOMETRY FOR LEAFLET (rendering only) ---------
# Applied here, AFTER the model is fit and all spill_/wx_/raw_ columns
# are attached - NOT before poly2nb()/nb2listw(). This keeps the queen
# contiguity structure (and therefore SDM and impacts_table) byte-for-byte
# identical to the canonical RQ3 script; only the polygon geometry actually
# drawn in Leaflet is reprojected/simplified, which is purely a rendering
# concern and has zero effect on the model above.
#
# NOTE: ms_simplify/st_simplify do NOT reorder or drop rows (with
# keep_shapes = TRUE), so the row index of map_data_spill stays aligned
# with the one used by nb_queen/W_sparse/SDM. This is essential for the
# what-if simulator in section 8, which indexes municipalities by row
# number.
map_data_spill <- map_data_spill %>%
  st_transform(4326)   # leaflet requires WGS84 lon/lat

if (requireNamespace("rmapshaper", quietly = TRUE)) {
  # topology-preserving: shared borders between adjacent municipalities
  # stay shared (no gaps/slivers appear), unlike sf::st_simplify()
  map_data_spill <- rmapshaper::ms_simplify(map_data_spill, keep = 0.05, keep_shapes = TRUE)
} else {
  message("Package 'rmapshaper' not installed: falling back to sf::st_simplify() ",
          "(this can create micro-gaps between neighbouring municipalities). ",
          "For a cleaner result: install.packages('rmapshaper').")
  map_data_spill <- st_simplify(map_data_spill, dTolerance = 0.0015, preserveTopology = TRUE)
}

# DEFENSIVE FIX: some rmapshaper/mapshaper versions drop or corrupt the CRS
# attribute during the GeoJSON round-trip used internally, even though the
# coordinate values themselves stay correct WGS84 lon/lat. Without a
# properly tagged CRS, Leaflet fails to fill the polygons (only borders/
# base tiles show) - this reasserts EPSG:4326 explicitly regardless of
# which simplification path was taken above.
if (is.na(st_crs(map_data_spill)) || st_crs(map_data_spill)$epsg != 4326) {
  st_crs(map_data_spill) <- 4326
}
# Simplification can occasionally produce self-intersecting/invalid
# geometry - repair it so Leaflet doesn't silently fail to fill affected
# polygons.
map_data_spill <- st_make_valid(map_data_spill)

stopifnot(nrow(map_data_spill) == nrow(map_data))  # index alignment, see note above

spill_cols <- paste0("spill_", spill_vars)

# Instead of ONE global max shared by all variables (which washes out
# the color scale for any variable with smaller effects than the
# largest one), compute a max |spillover| PER VARIABLE. This drives
# the color palette for whichever variable is currently selected on
# tab 2.
max_abs_spill_var <- sapply(spill_cols, function(col) {
  m <- max(abs(map_data_spill[[col]]), na.rm = TRUE)
  if (!is.finite(m) || m == 0) m <- 1e-6
  m
})
names(max_abs_spill_var) <- spill_vars

p_indirect_map <- setNames(impacts_table$p_indirect, as.character(impacts_table$variable))
spill_type_map <- setNames(impacts_table$spillover_type, as.character(impacts_table$variable))

## 8. WHAT-IF SIMULATOR: PRE-COMPUTE SPARSE SOLVER -------------------------
n_obs <- nrow(map_data_spill)
rho_hat <- SDM$rho

# Rebuild the design matrix X ourselves (instead of relying on an
# undocumented internal slot such as SDM$X): recompute it with
# model.matrix() on the SAME formula/data passed to lagsarlm, add the
# WX columns for the Durbin variables using the same listw used at
# estimation time, then reorder columns by NAME to match the model's
# coefficients. If anything doesn't line up (e.g. a spatialreg version
# that names the "lag." terms differently), the stopifnot() below fails
# explicitly instead of silently producing wrong numbers.
X_base <- model.matrix(model_formula, data = map_data_spill)
for (v in spill_vars) {
  X_base <- cbind(X_base, map_data_spill[[paste0("wx_", v)]])
  colnames(X_base)[ncol(X_base)] <- paste0("lag.", v)
}
stopifnot("SDM coefficient names not found in the rebuilt X_base: check formula/Durbin spec" =
            all(names(SDM$coefficients) %in% colnames(X_base)))
X_base <- X_base[, names(SDM$coefficients), drop = FALSE]

I_n <- Matrix::Diagonal(n_obs)
A_mat <- I_n - rho_hat * W_sparse
A_lu <- Matrix::lu(A_mat)   # reusable factorization: every later solve() is cheap

baseline_rhs <- as.numeric(X_base %*% SDM$coefficients)
baseline_signal <- as.numeric(Matrix::solve(A_lu, baseline_rhs))   # log(1+stays) predicted by the model
baseline_stays_hat <- expm1(baseline_signal)

map_data_spill$baseline_signal <- baseline_signal
map_data_spill$baseline_stays_hat <- baseline_stays_hat

beta_lookup <- setNames(as.numeric(SDM$coefficients[spill_vars]), spill_vars)
theta_lookup <- setNames(
  sapply(spill_vars, function(v) {
    nm <- paste0("lag.", v)
    if (nm %in% names(SDM$coefficients)) unname(SDM$coefficients[nm]) else 0
  }),
  spill_vars
)

#' Recompute predicted overnight stays after setting variable `v` in
#' municipality (row) `m_idx` to the ABSOLUTE target value
#' `target_raw`. `target_raw` is expressed in the same (log, but
#' UN-standardized) units as raw_<v> / the What-if slider - NOT in
#' standardized units. Internally it is converted to the standardized
#' scale the model was fit on before computing the shock. Returns a
#' data.frame for ALL municipalities (a single sparse solve, then only
#' O(n) vector algebra), so downstream code can look at the whole
#' network, not just the direct neighbours of m_idx.
whatif_predict <- function(m_idx, v, target_raw) {
  x_col <- X_base[, v]                 # current standardized values, all rows
  sp <- scale_params[[v]]
  target_std <- (target_raw - sp$mean) / sp$sd
  
  delta_v <- numeric(n_obs)
  delta_v[m_idx] <- target_std - x_col[m_idx]
  
  Wdelta <- as.numeric(W_sparse %*% delta_v)   # non-zero only for neighbours of m_idx
  delta_rhs <- beta_lookup[[v]] * delta_v + theta_lookup[[v]] * Wdelta
  
  delta_signal <- as.numeric(Matrix::solve(A_lu, delta_rhs))
  new_signal <- baseline_signal + delta_signal
  new_stays <- expm1(new_signal)
  
  idx_vec <- seq_len(n_obs)
  data.frame(
    idx = idx_vec,
    municipality_id = map_data_spill$municipality_id,
    municipality_name = map_data_spill$municipality_name,
    baseline_stays = baseline_stays_hat,
    new_stays = new_stays,
    delta_stays = new_stays - baseline_stays_hat,
    pct_change = ifelse(baseline_stays_hat > 0,
                        100 * (new_stays - baseline_stays_hat) / baseline_stays_hat,
                        NA_real_),
    is_selected = idx_vec == m_idx,
    is_neighbour = idx_vec %in% nb_queen[[m_idx]]
  )
}

## 9. SHINY APP ------------------------------------------------------------
ui <- fluidPage(
  titlePanel("Italian Municipal Tourism Explorer"),
  tabsetPanel(
    id = "main_tabs",
    
    ## TAB 1 — default view: observed overnight stays --------------------
    tabPanel("Night stays",
             sidebarLayout(
               sidebarPanel(
                 helpText("Observed overnight stays per municipality (logarithmic color scale)."),
                 
                 # ---- Variable descriptions (fixed) ----
                 h4("Variable descriptions"),
                 helpText(
                   tags$ul(
                     tags$li("Overnight stays – total tourist nights in accommodation"),
                     tags$li("Hotel beds – capacity in hotels and tourist residences"),
                     tags$li("Non‑hotel beds – capacity in campsites, B&Bs, etc."),
                     tags$li("Coastline (km) – length of sea coast within municipality"),
                     tags$li("Lake shoreline (km) – length of lake shore within municipality"),
                     tags$li("Protected areas (km²) – area of nature reserves and protected zones"),
                     tags$li("Museums – number of museums, galleries, monuments"),
                     tags$li("Architectural features – churches, castles, palaces, etc."),
                     tags$li("Sports facilities – sports centres, marinas, ski lifts, etc."),
                     tags$li("Nature‑based activities – hiking routes, alpine huts, campsites, spas"),
                     tags$li("Theme parks – number of amusement and water parks"),
                     tags$li("Nightlife – bars, pubs, nightclubs"),
                     tags$li("Public transport points – bus stops, railway stations"),
                     tags$li("Airport distance (km) – straight‑line distance to nearest airport"),
                     tags$li("UNESCO sites – number of World Heritage Sites"),
                     tags$li("Island municipality – classified as island or mainland"),
                     tags$li("Altitude zone – ISTAT altimetric classification (mountain/hill/plain, coastal/inland)")
                   )
                 ),
                 helpText("Click on a municipality to view its detailed data in the popup.")
               ),
               mainPanel(
                 leafletOutput("map_stays", height = 700)
               )
             )
    ),
    
    ## TAB 2 — spillover explorer (simplified sidebar) --------------------
    tabPanel("Spillover",
             sidebarLayout(
               sidebarPanel(
                 selectInput("spill_var",
                             "Spillover variable",
                             choices = spill_vars,
                             selected = "log_nature"),
                 
                 radioButtons("sign_filter",
                              "Spillover sign",
                              choices = c("All", "Complementary (positive)", "Competitive (negative)"),
                              selected = "All"),
                 
                 helpText("Map of the estimated spillover effect theta * WX",
                          "for the selected variable, as estimated by the model",
                          "(no scenario multiplier applied). Use the sign filter",
                          "to isolate complementary (positive) or competitive",
                          "(negative) spillovers.")
               ),
               mainPanel(
                 leafletOutput("map_spill", height = 700)
               )
             )
    ),
    
    ## TAB 3 — what-if for a single municipality ---------------------------
    tabPanel("What-if",
             sidebarLayout(
               sidebarPanel(
                 selectizeInput("whatif_comune", "Municipality",
                                choices = NULL,
                                options = list(placeholder = "Search a municipality...",
                                               maxOptions = 20)),
                 
                 selectInput("whatif_var", "Variable to change",
                             choices = spill_vars, selected = spill_vars[1]),
                 
                 sliderInput("whatif_value",
                             "Value of the variable (log scale, absolute)",
                             min = 0, max = 1, value = 0, step = 0.01),
                 
                 helpText("The slider is centered on the true current value of",
                          "the selected variable for the selected municipality,",
                          "and lets you move it between 0 (variable removed) and",
                          "twice that value. The map and the tables below then",
                          "show the resulting change in predicted overnight",
                          "stays for EVERY municipality in the network, not just",
                          "the immediate neighbours (blue border = direct",
                          "neighbour of the selected municipality; black border",
                          "= selected municipality).",
                          "Click a municipality on the map to select it, or",
                          "search for it above."),
                 hr(),
                 strong("Selected municipality"),
                 tableOutput("whatif_selected_table"),
                 strong("Top 10 municipalities by variation (ranked by % change)"),
                 tableOutput("whatif_top_table")
               ),
               mainPanel(
                 leafletOutput("map_whatif", height = 700)
               )
             )
    )
  )
)

server <- function(input, output, session) {
  
  ## ---------- TAB 1: night stays (static) -----------------
  output$map_stays <- renderLeaflet({
    # ---- Define display variables and labels ----
    display_vars <- list(
      total_overnight_stays      = "Overnight stays",
      total_hotel_beds           = "Hotel beds",
      total_non_hotel_beds       = "Non‑hotel beds",
      sea_coast_km               = "Coastline (km)",
      lake_coast_km              = "Lake shoreline (km)",
      protected_areas_sqkm       = "Protected areas (km²)",
      museums                    = "Museums",
      architectural_features     = "Architectural features",
      sports_facilities          = "Sports facilities",
      nature_based               = "Nature‑based activities",
      theme_parks                = "Theme parks",
      nightlife                  = "Nightlife",
      public_transport_points    = "Public transport points",
      airport_straight_km        = "Airport distance (km)",
      n_unesco_sites             = "UNESCO sites",
      island_municipality        = "Island municipality",
      altitude_zone              = "Altitude zone"
    )
    
    pal_obs <- colorNumeric("YlOrRd", domain = log1p(map_data_spill$total_overnight_stays))
    
    # Build popup HTML for each row
    dat <- map_data_spill
    popup_list <- lapply(seq_len(nrow(dat)), function(i) {
      html <- paste0("<b>", dat$municipality_name[i], "</b><br>")
      for (v in names(display_vars)) {
        label <- display_vars[[v]]
        val <- dat[[v]][i]
        formatted <- NA_character_
        
        if (is.factor(val)) {
          formatted <- as.character(val)
        } else if (is.numeric(val)) {
          if (v %in% c("total_overnight_stays", "total_hotel_beds", "total_non_hotel_beds",
                       "museums", "architectural_features", "sports_facilities",
                       "nature_based", "theme_parks", "nightlife",
                       "public_transport_points", "n_unesco_sites")) {
            formatted <- format(round(val), big.mark = ",")
          } else {
            formatted <- sprintf("%.2f", val)
          }
        } else {
          formatted <- as.character(val)
        }
        
        if (v == "total_overnight_stays") {
          html <- paste0(html, "<b>", label, ": ", formatted, "</b><br>")
        } else {
          html <- paste0(html, label, ": ", formatted, "<br>")
        }
      }
      sub("<br>$", "", html)
    })
    dat$popup_html <- unlist(popup_list)
    
    leaflet(dat, options = leafletOptions(preferCanvas = TRUE)) %>%
      addTiles() %>%
      setView(lng = 12.5, lat = 42.5, zoom = 6) %>%
      addPolygons(
        fillColor = ~pal_obs(log1p(total_overnight_stays)),
        weight = 0.3,
        color = "white",
        fillOpacity = 0.8,
        smoothFactor = 1.5,
        layerId = ~as.character(seq_len(nrow(dat))),
        label = ~municipality_name,
        popup = ~popup_html,
        highlightOptions = highlightOptions(color = "black", weight = 2, bringToFront = TRUE)
      ) %>%
      addLegend(
        position = "bottomright",
        pal = pal_obs,
        values = log1p(dat$total_overnight_stays),
        title = "Observed overnight stays",
        labFormat = labelFormat(big.mark = ",", digits = 0,
                                transform = function(x) round(expm1(x))),
        opacity = 0.8
      )
  })
  
  ## ---------- TAB 2: spillover explorer (simplified) ----------------------
  output$map_spill <- renderLeaflet({
    req(input$spill_var)
    v <- input$spill_var
    spill_name <- paste0("spill_", v)
    wx_name <- paste0("wx_", v)
    
    dat <- map_data_spill
    dat$spill_value <- dat[[spill_name]]
    dat$wx_value <- dat[[wx_name]]
    dat$selected_var_value <- dat[[v]]
    
    p_ind_val <- p_indirect_map[[v]]
    spill_type_val <- spill_type_map[[v]]
    dat$p_indirect <- p_ind_val
    dat$spill_type <- spill_type_val
    
    # Apply sign filter
    if (input$sign_filter == "Complementary (positive)") {
      dat <- dat %>% filter(spill_value > 0)
    } else if (input$sign_filter == "Competitive (negative)") {
      dat <- dat %>% filter(spill_value < 0)
    }
    
    var_max <- max_abs_spill_var[[v]]
    pal <- colorNumeric("RdBu", domain = c(-var_max, var_max), reverse = TRUE)
    
    dat <- dat %>%
      mutate(popup_html = paste0(
        "<b>", municipality_name, "</b><br>",
        "Overnight stays: ", round(total_overnight_stays), "<br>",
        "Selected variable (standardized): ", round(selected_var_value, 3), "<br>",
        "Neighbours' variable (WX): ", round(wx_value, 3), "<br>",
        "Spillover effect (theta*WX): ", round(spill_value, 3), "<br>",
        "Indirect p-value: ", ifelse(is.na(p_indirect), "NA", sprintf("%.3f", p_indirect)), "<br>",
        "Spillover type: ", spill_type
      ))
    
    leaflet(dat, options = leafletOptions(preferCanvas = TRUE)) %>%
      addTiles() %>%
      setView(lng = 12.5, lat = 42.5, zoom = 6) %>%
      addPolygons(
        fillColor = ~pal(spill_value),
        weight = 0.5,
        color = "white",
        fillOpacity = 0.8,
        smoothFactor = 1.5,
        label = ~municipality_name,
        popup = ~popup_html,
        highlightOptions = highlightOptions(color = "black", weight = 2, bringToFront = TRUE)
      ) %>%
      addLegend(
        position = "bottomright",
        pal = pal,
        values = c(-var_max, var_max),
        title = paste0("Spillover effect<br>(", v, ")"),
        opacity = 0.8
      )
  })
  
  ## ---------- TAB 3: what-if for a single municipality ---------------------
  
  # server-side population of the municipality menu (7900+ options:
  # server=TRUE avoids shipping the whole list to the client)
  observe({
    updateSelectizeInput(session, "whatif_comune",
                         choices = setNames(as.character(seq_len(n_obs)),
                                            map_data_spill$municipality_name),
                         server = TRUE)
  })
  
  m_idx <- reactive({
    val <- input$whatif_comune
    if (is.null(val) || val == "") return(NA_integer_)
    suppressWarnings(as.integer(val))
  })
  
  observeEvent(input$map_whatif_shape_click, {
    click <- input$map_whatif_shape_click
    req(click$id)
    updateSelectizeInput(session, "whatif_comune", selected = click$id)
  })
  
  # Keep the slider centered on the TRUE current value of the selected
  # variable for the selected municipality, ranging from 0 to twice
  # that value, every time the municipality or the variable changes.
  observe({
    idx <- m_idx()
    v <- input$whatif_var
    req(!is.na(idx), v)
    
    cur <- map_data_spill[[paste0("raw_", v)]][idx]
    # these are log(1+x) variables, so cur is always >= 0; guard the
    # degenerate cur == 0 case so the slider doesn't collapse to a
    # single point
    upper <- if (is.finite(cur) && cur > 0) 2 * cur else 1
    
    updateSliderInput(session, "whatif_value",
                      min = 0, max = upper, value = cur,
                      step = upper / 100)
  })
  
  whatif_value_d <- reactive(input$whatif_value) %>% debounce(200)
  
  whatif_result <- reactive({
    idx <- m_idx()
    if (is.na(idx)) {
      # no municipality selected yet: show the unperturbed baseline map
      idx_vec <- seq_len(n_obs)
      return(data.frame(
        idx = idx_vec,
        municipality_id = map_data_spill$municipality_id,
        municipality_name = map_data_spill$municipality_name,
        baseline_stays = baseline_stays_hat,
        new_stays = baseline_stays_hat,
        delta_stays = 0,
        pct_change = 0,
        is_selected = FALSE,
        is_neighbour = FALSE
      ))
    }
    req(input$whatif_var)
    whatif_predict(idx, input$whatif_var, whatif_value_d())
  })
  
  output$map_whatif <- renderLeaflet({
    leaflet(options = leafletOptions(preferCanvas = TRUE)) %>%
      addTiles() %>%
      setView(lng = 12.5, lat = 42.5, zoom = 6)
  })
  
  observe({
    res <- whatif_result()
    
    dat <- map_data_spill
    dat$new_stays <- res$new_stays
    dat$baseline_stays <- res$baseline_stays
    dat$delta_stays <- res$delta_stays
    dat$pct_change <- res$pct_change
    dat$is_selected <- res$is_selected
    dat$is_neighbour <- res$is_neighbour
    
    # color domain recomputed on the current values (so it doesn't
    # saturate/clip if the scenario pushes a municipality beyond the
    # baseline observed range)
    pal <- colorNumeric("YlOrRd", domain = log1p(pmax(dat$new_stays, 0)))
    
    dat <- dat %>%
      mutate(
        border_color = case_when(
          is_selected  ~ "black",
          is_neighbour ~ "#1f78b4",
          TRUE         ~ "white"
        ),
        border_weight = case_when(
          is_selected  ~ 3,
          is_neighbour ~ 2,
          TRUE         ~ 0.3
        ),
        popup_html = paste0(
          "<b>", municipality_name, "</b><br>",
          "Predicted stays (baseline): ", format(round(baseline_stays), big.mark = ","), "<br>",
          "Predicted stays (scenario): ", format(round(new_stays), big.mark = ","), "<br>",
          "Change: ", ifelse(delta_stays >= 0, "+", ""), format(round(delta_stays), big.mark = ","),
          " (", sprintf("%+.1f", pct_change), "%)"
        )
      )
    
    proxy <- leafletProxy("map_whatif", data = dat)
    proxy %>% clearShapes() %>% clearControls()
    
    proxy %>%
      addPolygons(
        fillColor = ~pal(log1p(pmax(new_stays, 0))),
        weight = ~border_weight,
        color = ~border_color,
        fillOpacity = 0.8,
        smoothFactor = 1.5,
        layerId = ~as.character(seq_len(nrow(dat))),
        label = ~municipality_name,
        popup = ~popup_html,
        highlightOptions = highlightOptions(color = "black", weight = 2, bringToFront = TRUE)
      ) %>%
      addLegend(
        position = "bottomright",
        pal = pal,
        values = log1p(pmax(dat$new_stays, 0)),
        title = "Predicted overnight stays",
        labFormat = labelFormat(big.mark = ",", digits = 0,
                                transform = function(x) round(expm1(x))),
        opacity = 0.8
      )
  })
  
  fmt_whatif_table <- function(rows) {
    rows <- rows[, c("municipality_name", "baseline_stays", "new_stays", "delta_stays", "pct_change")]
    rows$baseline_stays <- format(round(rows$baseline_stays), big.mark = ",")
    rows$new_stays <- format(round(rows$new_stays), big.mark = ",")
    rows$delta_stays <- paste0(ifelse(rows$delta_stays >= 0, "+", ""),
                               format(round(rows$delta_stays), big.mark = ","))
    rows$pct_change <- sprintf("%+.1f%%", rows$pct_change)
    names(rows) <- c("Municipality", "Baseline", "Scenario", "Change", "Change %")
    rows
  }
  
  output$whatif_selected_table <- renderTable({
    idx <- m_idx()
    req(!is.na(idx))
    res <- whatif_result()
    fmt_whatif_table(res[res$idx == idx, ])
  }, striped = TRUE)
  
  output$whatif_top_table <- renderTable({
    idx <- m_idx()
    req(!is.na(idx))
    res <- whatif_result()
    
    # Rank across ALL municipalities except the selected one (which is
    # already shown in its own table above), using PERCENT change
    # rather than raw change: a large city and a tiny hamlet are on
    # very different absolute scales, so ranking by raw delta_stays
    # would just surface the biggest municipalities every time,
    # regardless of how much the scenario actually moved them.
    others <- res[res$idx != idx, ]
    top10 <- others[order(-abs(others$pct_change)), ][seq_len(min(10, nrow(others))), ]
    # 
    out <- fmt_whatif_table(top10)
    out$Neighbour <- ifelse(top10$is_neighbour, "Yes", "No")
    out
  }, striped = TRUE)
}

shinyApp(ui, server)