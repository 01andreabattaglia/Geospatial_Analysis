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

raw_scale_vars <- map_data %>% st_drop_geometry() %>% select(all_of(scale_vars))

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

selector_vars <- c("log_hotel_beds", "log_non_hotel_beds",
                   "log_sports", "log_nature", "log_transport_pts")

spill_var_meta <- list(
  log_hotel_beds     = list(label = "Hotel beds",
                            desc = "Capacity in hotels and tourist residences"),
  log_non_hotel_beds = list(label = "Non\u2011hotel beds",
                            desc = "Capacity in campsites, B&Bs, etc."),
  log_sea_coast_km   = list(label = "Coastline (km)",
                            desc = "Length of sea coast within municipality"),
  log_lake_coast_km  = list(label = "Lake shoreline (km)",
                            desc = "Length of lake shore within municipality"),
  log_protected_area = list(label = "Protected areas (km\u00b2)",
                            desc = "Area of nature reserves and protected zones"),
  log_sports         = list(label = "Sports facilities",
                            desc = "Sports centres, marinas, ski lifts, etc."),
  log_nature         = list(label = "Nature\u2011based activities",
                            desc = "Hiking routes, alpine huts, campsites, spas"),
  log_transport_pts  = list(label = "Public transport points",
                            desc = "Bus stops, railway stations")
)

spill_var_raw_col <- list(
  log_hotel_beds     = "total_hotel_beds",
  log_non_hotel_beds = "total_non_hotel_beds",
  log_sports         = "sports_facilities",
  log_nature         = "nature_based",
  log_transport_pts  = "public_transport_points"
)

whatif_var_unit <- list(
  log_hotel_beds     = "beds",
  log_non_hotel_beds = "beds",
  log_sea_coast_km   = "km",
  log_lake_coast_km  = "km",
  log_protected_area = "km\u00b2",
  log_sports         = "facilities",
  log_nature         = "activities",
  log_transport_pts  = "stops"
)

whatif_var_choices <- setNames(
  spill_vars,
  vapply(spill_vars, function(v) spill_var_meta[[v]]$label, character(1))
)

spill_var_choices <- setNames(
  selector_vars,
  vapply(selector_vars, function(v) spill_var_meta[[v]]$label, character(1))
)

map_data_spill <- map_data

for (v in spill_vars) {
  wx_name <- paste0("wx_", v)
  spill_name <- paste0("spill_", v)
  theta_name <- names(SDM$coefficients)[grepl(paste0("^lag\\.", v, "$"), names(SDM$coefficients))]
  theta <- unname(SDM$coefficients[theta_name])
  
  map_data_spill[[wx_name]] <- lag.listw(listw_queen, map_data_spill[[v]], zero.policy = TRUE)
  map_data_spill[[spill_name]] <- theta * map_data_spill[[wx_name]]
}

for (v in selector_vars) {
  raw_col <- spill_var_raw_col[[v]]
  map_data_spill[[paste0("rawwx_", v)]] <- lag.listw(listw_queen, map_data_spill[[raw_col]], zero.policy = TRUE)
}

for (v in scale_vars) {
  map_data_spill[[paste0("raw_", v)]] <- raw_scale_vars[[v]]
}

## 7b. REPROJECT + SIMPLIFY GEOMETRY FOR LEAFLET (rendering only) ---------
map_data_spill <- map_data_spill %>%
  st_transform(4326)

if (requireNamespace("rmapshaper", quietly = TRUE)) {
  map_data_spill <- rmapshaper::ms_simplify(map_data_spill, keep = 0.05, keep_shapes = TRUE)
} else {
  message("Package 'rmapshaper' not installed: falling back to sf::st_simplify() ",
          "(this can create micro-gaps between neighbouring municipalities). ",
          "For a cleaner result: install.packages('rmapshaper').")
  map_data_spill <- st_simplify(map_data_spill, dTolerance = 0.0015, preserveTopology = TRUE)
}

if (is.na(st_crs(map_data_spill)) || st_crs(map_data_spill)$epsg != 4326) {
  st_crs(map_data_spill) <- 4326
}
map_data_spill <- st_make_valid(map_data_spill)

stopifnot(nrow(map_data_spill) == nrow(map_data))

spill_cols <- paste0("spill_", spill_vars)

max_abs_spill_var <- sapply(spill_cols, function(col) {
  m <- max(abs(map_data_spill[[col]]), na.rm = TRUE)
  if (!is.finite(m) || m == 0) m <- 1e-6
  m
})
names(max_abs_spill_var) <- spill_vars

p_indirect_map <- setNames(impacts_table$p_indirect, as.character(impacts_table$variable))
spill_type_map <- setNames(impacts_table$spillover_type, as.character(impacts_table$variable))

## 7c. ITALIAN REGION BOUNDARIES (rendering only) -------------------------
region_col <- intersect(c("COD_REG", "COD_REG_ISTAT", "REGIONE", "DEN_REG"), names(comuni_sf))
stopifnot("Region code/name column not found in comuni_sf - check the ISTAT shapefile field names (expected e.g. COD_REG)" =
            length(region_col) > 0)
region_col <- region_col[1]

regioni_sf <- comuni_sf %>%
  st_make_valid() %>%
  group_by(across(all_of(region_col))) %>%
  summarise(.groups = "drop") %>%
  st_transform(4326)

if (requireNamespace("rmapshaper", quietly = TRUE)) {
  regioni_sf <- rmapshaper::ms_simplify(regioni_sf, keep = 0.05, keep_shapes = TRUE)
} else {
  regioni_sf <- st_simplify(regioni_sf, dTolerance = 0.0015, preserveTopology = TRUE)
}
if (is.na(st_crs(regioni_sf)) || st_crs(regioni_sf)$epsg != 4326) {
  st_crs(regioni_sf) <- 4326
}
regioni_sf <- st_make_valid(regioni_sf)

regioni_boundary <- st_boundary(regioni_sf)

## 8. WHAT-IF SIMULATOR: PRE-COMPUTE SPARSE SOLVER -------------------------
n_obs <- nrow(map_data_spill)
rho_hat <- SDM$rho

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
A_lu <- Matrix::lu(A_mat)

baseline_rhs <- as.numeric(X_base %*% SDM$coefficients)
baseline_signal <- as.numeric(Matrix::solve(A_lu, baseline_rhs))
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

whatif_predict <- function(m_idx, v, target_raw) {
  x_col <- X_base[, v]
  sp <- scale_params[[v]]
  target_std <- (target_raw - sp$mean) / sp$sd
  
  delta_v <- numeric(n_obs)
  delta_v[m_idx] <- target_std - x_col[m_idx]
  
  Wdelta <- as.numeric(W_sparse %*% delta_v)
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

## 8b. GLOBAL DISPLAY VARIABLE DEFINITIONS (Tab 1) -------------------------
display_vars <- list(
  total_overnight_stays      = "Overnight stays",
  total_hotel_beds           = "Hotel beds",
  total_non_hotel_beds       = "Non\u2011hotel beds",
  sea_coast_km               = "Coastline (km)",
  lake_coast_km              = "Lake shoreline (km)",
  protected_areas_sqkm       = "Protected areas (km\u00b2)",
  museums                    = "Museums",
  architectural_features     = "Architectural features",
  sports_facilities          = "Sports facilities",
  nature_based               = "Nature\u2011based activities",
  theme_parks                = "Theme parks",
  nightlife                  = "Nightlife",
  public_transport_points    = "Public transport points",
  airport_straight_km        = "Airport distance (km)",
  n_unesco_sites             = "UNESCO sites",
  island_municipality        = "Island municipality",
  altitude_zone              = "Altitude zone"
)

tab1_count_vars <- c("total_overnight_stays", "total_hotel_beds", "total_non_hotel_beds",
                     "museums", "architectural_features", "sports_facilities",
                     "nature_based", "theme_parks", "nightlife",
                     "public_transport_points", "n_unesco_sites")

tab1_var_choices <- setNames(names(display_vars), unlist(display_vars, use.names = FALSE))

## 9. SHINY APP ------------------------------------------------------------
ui <- fluidPage(
  tags$head(tags$style(HTML("
    .whatif-table-wrap { width: 100%; overflow-x: hidden; margin-bottom: 12px; }
    .whatif-table-wrap table { width: 100% !important; table-layout: fixed; font-size: 11px; margin-bottom: 0; }
    .whatif-table-wrap th, .whatif-table-wrap td {
      overflow-wrap: break-word;
      word-break: break-word;
      white-space: normal;
      padding: 3px 4px;
    }
  "))),
  titlePanel("Italian Municipal Tourism Explorer"),
  tabsetPanel(
    id = "main_tabs",
    
    tabPanel("Night stays",
             sidebarLayout(
               sidebarPanel(
                 selectInput("stays_var",
                             "Variable",
                             choices = tab1_var_choices,
                             selected = "total_overnight_stays"),
                 
                 helpText("Distribution of the selected variable across municipalities",
                          "(logarithmic color scale for numeric variables; categorical",
                          "variables use a qualitative palette). Defaults to observed",
                          "overnight stays."),
                 
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
    
    tabPanel("Spillover",
             sidebarLayout(
               sidebarPanel(
                 selectInput("spill_var",
                             "Spillover variable",
                             choices = spill_var_choices,
                             selected = "log_nature"),
                 
                 uiOutput("spill_overall_effect"),
                 
                 helpText("Estimated spillover effect of the selected resource on",
                          "overnight stays in neighbouring municipalities. Click a",
                          "municipality to see its own value, its neighbours'",
                          "average, and the resulting effect as a % change in",
                          "overnight stays (positive = complementary, negative =",
                          "competitive)."),
                 
                 h4("Variable descriptions"),
                 helpText(
                   do.call(tags$ul,
                           lapply(selector_vars, function(v) {
                             meta <- spill_var_meta[[v]]
                             tags$li(paste0(meta$label, " – ", meta$desc))
                           })
                   )
                 )
               ),
               mainPanel(
                 leafletOutput("map_spill", height = 700)
               )
             )
    ),
    
    tabPanel("What-if",
             sidebarLayout(
               sidebarPanel(
                 selectizeInput("whatif_comune", "Municipality",
                                choices = NULL,
                                options = list(placeholder = "Search a municipality...",
                                               maxOptions = 20)),
                 
                 selectInput("whatif_var", "Resource to simulate",
                             choices = whatif_var_choices,
                             selected = whatif_var_choices[[1]]),
                 
                 sliderInput("whatif_value",
                             "Target value",
                             min = 0, max = 1, value = 0, step = 0.01),
                 
                 helpText("The slider is centered on the municipality's actual,",
                          "real-world current value of the selected resource",
                          "(e.g. number of beds, kilometres of coastline) and",
                          "lets you move it between 0 (resource removed) and",
                          "twice that value. The map and the tables below then",
                          "show the resulting change in predicted overnight",
                          "stays for EVERY municipality in the network, not just",
                          "the immediate neighbours (blue border = direct",
                          "neighbour of the selected municipality; black border",
                          "= selected municipality). Click any municipality on",
                          "the map to select it and inspect its own resulting",
                          "variation, or search for it above."),
                 
                 h4("Variable descriptions"),
                 helpText(
                   do.call(tags$ul,
                           lapply(spill_vars, function(v) {
                             meta <- spill_var_meta[[v]]
                             tags$li(paste0(meta$label, " – ", meta$desc))
                           })
                   )
                 ),
                 hr(),
                 strong("Selected municipality"),
                 div(class = "whatif-table-wrap",
                     tableOutput("whatif_selected_table")),
                 strong("Top 10 municipalities by variation (ranked by % change)"),
                 div(class = "whatif-table-wrap",
                     tableOutput("whatif_top_table"))
               ),
               mainPanel(
                 leafletOutput("map_whatif", height = 700)
               )
             )
    )
  )
)

server <- function(input, output, session) {
  
  ## ---------- TAB 1: variable distribution explorer -----------------
  output$map_stays <- renderLeaflet({
    req(input$stays_var)
    v <- input$stays_var
    v_label <- display_vars[[v]]
    
    dat <- map_data_spill
    val <- dat[[v]]
    is_cat <- is.factor(val) || is.character(val)
    
    if (is_cat) {
      pal_obs <- colorFactor("Set2", domain = val)
      dat$fill_val <- val
    } else {
      pal_obs <- colorNumeric("YlOrRd", domain = log1p(val))
      dat$fill_val <- log1p(val)
    }
    
    popup_list <- lapply(seq_len(nrow(dat)), function(i) {
      html <- paste0("<b>", dat$municipality_name[i], "</b><br>")
      for (dv in names(display_vars)) {
        label <- display_vars[[dv]]
        cell <- dat[[dv]][i]
        formatted <- NA_character_
        
        if (is.factor(cell)) {
          formatted <- as.character(cell)
        } else if (is.numeric(cell)) {
          if (dv %in% tab1_count_vars) {
            formatted <- format(round(cell), big.mark = ",")
          } else {
            formatted <- sprintf("%.2f", cell)
          }
        } else {
          formatted <- as.character(cell)
        }
        
        if (dv == v) {
          html <- paste0(html, "<b>", label, ": ", formatted, "</b><br>")
        } else {
          html <- paste0(html, label, ": ", formatted, "<br>")
        }
      }
      sub("<br>$", "", html)
    })
    dat$popup_html <- unlist(popup_list)
    
    map <- leaflet(dat, options = leafletOptions(preferCanvas = TRUE)) %>%
      addTiles() %>%
      setView(lng = 12.5, lat = 42.5, zoom = 6) %>%
      addPolygons(
        fillColor = ~pal_obs(fill_val),
        weight = 0.3,
        color = "white",
        fillOpacity = 0.8,
        smoothFactor = 1.5,
        layerId = ~as.character(seq_len(nrow(dat))),
        label = ~municipality_name,
        popup = ~popup_html,
        group = "muni",
        highlightOptions = highlightOptions(color = "black", weight = 2, bringToFront = TRUE)
      ) %>%
      addPolylines(
        data = regioni_boundary,
        color = "#222222",
        weight = 2.5,
        opacity = 0.9,
        dashArray = "6,4",
        group = "regions",
        options = pathOptions(interactive = FALSE)
      )
    
    if (is_cat) {
      map <- map %>%
        addLegend(position = "bottomright", pal = pal_obs, values = dat$fill_val,
                  title = v_label, opacity = 0.8)
    } else {
      map <- map %>%
        addLegend(position = "bottomright", pal = pal_obs, values = dat$fill_val,
                  title = v_label,
                  labFormat = labelFormat(big.mark = ",", digits = 0,
                                          transform = function(x) round(expm1(x))),
                  opacity = 0.8)
    }
    
    map
  })
  
  ## ---------- TAB 2: overall (network-wide) effect, for cross-checking ----
  output$spill_overall_effect <- renderUI({
    req(input$spill_var)
    row <- impacts_table[impacts_table$variable == input$spill_var, ]
    req(nrow(row) == 1)
    
    tags$div(
      style = "background-color:#f5f5f5; padding:8px; border-radius:4px; margin-bottom:10px; font-size:13px;",
      tags$b("Overall effect (SDM impacts table)"), tags$br(),
      sprintf("Direct: %.4f", row$direct), tags$br(),
      sprintf("Indirect: %.4f (p = %s)", row$indirect,
              ifelse(is.na(row$p_indirect), "NA", sprintf("%.3f", row$p_indirect))), tags$br(),
      sprintf("Total: %.4f", row$total), tags$br(),
      paste0("Type: ", row$spillover_type)
    )
  })
  
  ## ---------- TAB 2: spillover explorer (5 variables, human-readable) -----
  output$map_spill <- renderLeaflet({
    req(input$spill_var)
    v <- input$spill_var
    v_label <- spill_var_meta[[v]]$label
    spill_name <- paste0("spill_", v)
    rawwx_name <- paste0("rawwx_", v)
    raw_col <- spill_var_raw_col[[v]]
    
    dat <- map_data_spill
    dat$spill_value <- dat[[spill_name]]
    dat$real_value <- dat[[raw_col]]
    dat$real_neighbour_avg <- dat[[rawwx_name]]
    
    dat$pct_effect <- 100 * (exp(dat$spill_value) - 1)
    
    var_max <- max_abs_spill_var[[v]]
    pal <- colorNumeric("RdBu", domain = c(-var_max, var_max), reverse = TRUE)
    
    dat <- dat %>%
      mutate(popup_html = paste0(
        "<b>", municipality_name, "</b><br>",
        "Overnight stays: ", format(round(total_overnight_stays), big.mark = ","), "<br>",
        v_label, ": ", format(round(real_value, 1), big.mark = ","), "<br>",
        "Neighbours' average ", v_label, ": ", format(round(real_neighbour_avg, 1), big.mark = ","), "<br>",
        "Estimated spillover effect: ", sprintf("%+.1f%%", pct_effect), " in overnight stays"
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
        group = "muni",
        highlightOptions = highlightOptions(color = "black", weight = 2, bringToFront = TRUE)
      ) %>%
      addPolylines(
        data = regioni_boundary,
        color = "#222222",
        weight = 2.5,
        opacity = 0.9,
        dashArray = "6,4",
        group = "regions",
        options = pathOptions(interactive = FALSE)
      ) %>%
      addLegend(
        position = "bottomright",
        pal = pal,
        values = c(-var_max, var_max),
        title = paste0("Spillover effect<br>(", v_label, ")"),
        opacity = 0.8
      )
  })
  
  ## ---------- TAB 3: what-if for a single municipality ---------------------
  
  whatif_comune_choices <- setNames(as.character(seq_len(n_obs)),
                                    map_data_spill$municipality_name)
  
  observe({
    updateSelectizeInput(session, "whatif_comune",
                         choices = whatif_comune_choices,
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
    updateSelectizeInput(session, "whatif_comune",
                         choices = whatif_comune_choices,
                         selected = click$id,
                         server = TRUE)
  })
  
  observe({
    idx <- m_idx()
    v <- input$whatif_var
    req(!is.na(idx), v)
    
    cur_log <- map_data_spill[[paste0("raw_", v)]][idx]
    cur_real <- expm1(cur_log)
    upper_real <- if (is.finite(cur_real) && cur_real > 0) 2 * cur_real else 1
    
    unit <- whatif_var_unit[[v]]
    label <- sprintf("Target value \u2014 %s (%s)", spill_var_meta[[v]]$label, unit)
    
    updateSliderInput(session, "whatif_value",
                      label = label,
                      min = 0, max = upper_real, value = cur_real,
                      step = upper_real / 100)
  })
  
  whatif_value_d <- reactive(input$whatif_value) %>% debounce(200)
  
  whatif_result <- reactive({
    idx <- m_idx()
    if (is.na(idx)) {
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
    target_log <- log1p(whatif_value_d())
    whatif_predict(idx, input$whatif_var, target_log)
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
    proxy %>% clearGroup("muni") %>% clearGroup("regions") %>% clearControls()
    
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
        group = "muni",
        highlightOptions = highlightOptions(color = "black", weight = 2, bringToFront = TRUE)
      ) %>%
      addPolylines(
        data = regioni_boundary,
        color = "#222222",
        weight = 2.5,
        opacity = 0.9,
        dashArray = "6,4",
        group = "regions",
        options = pathOptions(interactive = FALSE)
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
    names(rows) <- c("Municipality", "Before", "After", "\u0394", "\u0394 %")
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
    
    others <- res[res$idx != idx, ]
    top10 <- others[order(-abs(others$pct_change)), ][seq_len(min(10, nrow(others))), ]
    out <- fmt_whatif_table(top10)
    out$Neighbour <- ifelse(top10$is_neighbour, "Yes", "No")
    out
  }, striped = TRUE)
}

# shinyApp(ui, server)