# ============================================================
# Interactive spillover map for RQ3
# Shiny + Leaflet
# ============================================================

library(sf)
library(spdep)
library(spatialreg)
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
# IMPORTANT: no st_transform() here. The canonical
# RQ3 script fits poly2nb()/lagsarlm() on the
# shapefile's native CRS (EPSG:32632, despite the
# "_WGS84" filename). Reprojection is not exact at
# floating-point level - it can silently break or
# create shared-vertex touches between adjacent
# polygons, changing nb_queen/listw_queen and
# therefore SDM's Hessian (this is what caused the
# NaN warning that RQ3 itself does not produce).
# WGS84 (4326) reprojection for Leaflet is applied
# further down, AFTER the model is fit, to a
# render-only copy - see section 7b.

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
# (trW type, seed, R, and the safe_impacts fallback logic) so the impacts
# table - and therefore every p-value/spillover-type shown in the app -
# matches the published RQ3 results exactly. Do not "improve" this in
# isolation; if trExact/deterministic tracing is wanted, it needs to be
# changed in the canonical RQ3 script too, and results re-validated there.
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

## 7b. REPROJECT + SIMPLIFY GEOMETRY FOR LEAFLET (rendering only) ---------
# Applied here, AFTER the model is fit and all spill_/wx_ columns are
# attached - NOT before poly2nb()/nb2listw(). This keeps the queen
# contiguity structure (and therefore SDM and impacts_table) byte-for-byte
# identical to the canonical RQ3 script; only the polygon geometry actually
# drawn in Leaflet is reprojected/simplified, which is purely a rendering
# concern and has zero effect on the model above.
map_data_spill <- map_data_spill %>%
  st_transform(4326)   # leaflet requires WGS84 lon/lat

if (requireNamespace("rmapshaper", quietly = TRUE)) {
  # topology-preserving: shared borders between adjacent municipalities
  # stay shared (no gaps/slivers appear), unlike sf::st_simplify()
  map_data_spill <- rmapshaper::ms_simplify(map_data_spill, keep = 0.05, keep_shapes = TRUE)
} else {
  message("Pacchetto 'rmapshaper' non installato: uso sf::st_simplify() come ",
          "ripiego (puo' creare micro-fessure tra comuni confinanti). Per un ",
          "risultato pulito: install.packages('rmapshaper').")
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
# simplification can occasionally produce self-intersecting/invalid
# geometry - repair it so Leaflet doesn't silently fail to fill affected
# polygons.
map_data_spill <- st_make_valid(map_data_spill)

spill_cols <- paste0("spill_", spill_vars)

# FIX: instead of ONE global max shared by all variables (which washes out
# the color scale for any variable with smaller effects than the largest
# one), compute a max |spillover| PER VARIABLE. This is what drives the
# color palette and the slider for whichever variable is currently selected.
max_abs_spill_var <- sapply(spill_cols, function(col) {
  m <- max(abs(map_data_spill[[col]]), na.rm = TRUE)
  if (!is.finite(m) || m == 0) m <- 1e-6
  m
})
names(max_abs_spill_var) <- spill_vars

# keep a global fallback too (used only to set the initial slider bounds)
max_abs_spill_global <- max(max_abs_spill_var)

p_indirect_map <- setNames(impacts_table$p_indirect, as.character(impacts_table$variable))
spill_type_map <- setNames(impacts_table$spillover_type, as.character(impacts_table$variable))

## 8. SHINY APP ------------------------------------------------------------
ui <- fluidPage(
  titlePanel("Tourism spillover explorer — RQ3"),
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
      
      checkboxInput("significant_only",
                    "Only significant municipalities (indirect p < 0.10)",
                    value = FALSE),
      
      # NOTE: min/max/step are now updated dynamically per variable
      # (see observeEvent below) instead of using the global max.
      sliderInput("threshold",
                  "Minimum |spillover| to display",
                  min = 0,
                  max = max_abs_spill_global,
                  value = 0,
                  step = max_abs_spill_global / 100),
      
      sliderInput("multiplier",
                  "Scenario multiplier for selected resource",
                  min = 0,
                  max = 3,
                  value = 1,
                  step = 0.1),
      
      helpText("The multiplier simulates a simple 'what if' scenario:",
               "if the selected resource changes by this factor, the spillover",
               "theta * WX changes by the same factor.")
    ),
    mainPanel(
      leafletOutput("map", height = 700)
    )
  )
)

server <- function(input, output, session) {
  
  output$map <- renderLeaflet({
    # PERFORMANCE FIX: default SVG rendering creates one DOM element per
    # polygon - with ~7900 municipalities this is the main reason redraws
    # feel sluggish. preferCanvas draws everything on a single <canvas>,
    # which is dramatically faster for this many shapes.
    leaflet(map_data_spill, options = leafletOptions(preferCanvas = TRUE)) %>%
      addTiles() %>%
      setView(lng = 12.5, lat = 42.5, zoom = 6)
  })
  
  # PERFORMANCE FIX: sliders fire an update on every pixel of drag. Debounce
  # so we only react ~250ms after the user stops moving them, instead of on
  # every intermediate value.
  threshold_d <- reactive(input$threshold) %>% debounce(250)
  multiplier_d <- reactive(input$multiplier) %>% debounce(250)
  
  # Rescale the threshold slider whenever the selected variable changes,
  # so its range matches that variable's own spillover magnitude.
  observeEvent(input$spill_var, {
    v <- input$spill_var
    vmax <- max_abs_spill_var[[v]]
    updateSliderInput(session, "threshold",
                      min = 0, max = vmax, value = 0, step = vmax / 100)
  }, ignoreInit = TRUE)
  
  # PERFORMANCE FIX: split into two reactives.
  # var_data() does the "expensive" per-row work (selecting the right
  # spillover column, building popup text) and only reruns when the
  # selected variable or the (debounced) multiplier changes.
  # filtered() just does cheap row filtering on top of var_data()'s result,
  # so toggling sign/significance/threshold no longer re-triggers popup
  # generation - it used to rebuild popup_html for all ~7900 rows on every
  # single filter tweak, which was pure wasted work.
  var_data <- reactive({
    req(input$spill_var)
    v <- input$spill_var
    spill_name <- paste0("spill_", v)
    wx_name <- paste0("wx_", v)
    mult <- multiplier_d()
    
    dat <- map_data_spill
    dat$spill_value <- dat[[spill_name]] * mult
    dat$wx_value <- dat[[wx_name]]
    dat$selected_var_value <- dat[[v]]
    
    p_ind_val <- p_indirect_map[[v]]
    p_ind_val <- if (is.null(p_ind_val) || length(p_ind_val) != 1) NA_real_ else as.numeric(p_ind_val)
    
    spill_type_val <- spill_type_map[[v]]
    spill_type_val <- if (is.null(spill_type_val) || length(spill_type_val) != 1) "not tested" else as.character(spill_type_val)
    
    dat$p_indirect <- p_ind_val
    dat$spill_type <- spill_type_val
    
    dat %>%
      mutate(popup_html = paste0(
        "<b>", municipality_name, "</b><br>",
        "Overnight stays: ", round(total_overnight_stays), "<br>",
        "Selected variable (scaled): ", round(selected_var_value, 3), "<br>",
        "Neighbours' variable (WX): ", round(wx_value, 3), "<br>",
        "Spillover effect (theta*WX): ", round(spill_value, 3), "<br>",
        "Indirect p-value: ", ifelse(is.na(p_indirect), "NA", sprintf("%.3f", p_indirect)), "<br>",
        "Spillover type: ", spill_type
      ))
  })
  
  filtered <- reactive({
    dat <- var_data()
    
    if (input$sign_filter == "Complementary (positive)") {
      dat <- dat %>% filter(spill_value > 0)
    } else if (input$sign_filter == "Competitive (negative)") {
      dat <- dat %>% filter(spill_value < 0)
    }
    
    if (input$significant_only) {
      dat <- dat %>% filter(p_indirect < 0.10)
    }
    
    dat %>% filter(abs(spill_value) >= threshold_d())
  })
  
  # Current color domain: only changes with variable/multiplier, not with
  # sign/significance/threshold filters - kept as its own reactive so the
  # legend observer below doesn't refire on every filter tweak.
  var_max_r <- reactive({
    max_abs_spill_var[[input$spill_var]] * max(multiplier_d(), 1)
  })
  
  # PERFORMANCE FIX: legend redraw split out from polygon redraw. It only
  # needs to change when the variable or multiplier changes (domain
  # changes), not on every sign/significance/threshold filter tweak.
  observe({
    var_max <- var_max_r()
    v <- input$spill_var
    pal <- colorNumeric("RdBu", domain = c(-var_max, var_max), reverse = TRUE)
    
    leafletProxy("map") %>%
      clearControls() %>%
      addLegend(
        position = "bottomright",
        pal = pal,
        values = c(-var_max, var_max),
        title = paste0("Spillover effect<br>(", v, ")"),
        opacity = 0.8
      )
  })
  
  observe({
    dat <- filtered()
    var_max <- var_max_r()
    
    pal <- colorNumeric(
      palette = "RdBu",
      domain = c(-var_max, var_max),
      reverse = TRUE
    )
    
    proxy <- leafletProxy("map", data = dat)
    proxy %>% clearShapes()
    
    if (nrow(dat) > 0) {
      proxy %>%
        addPolygons(
          fillColor = ~pal(spill_value),
          weight = 0.5,
          color = "white",
          fillOpacity = 0.8,
          smoothFactor = 1.5,   # PERFORMANCE FIX: slightly coarser on-screen
          # rendering (client-side only, data untouched)
          label = ~municipality_name,
          popup = ~popup_html,
          highlightOptions = highlightOptions(
            color = "black",
            weight = 2,
            bringToFront = TRUE
          )
        )
    }
  })
}

shinyApp(ui, server)