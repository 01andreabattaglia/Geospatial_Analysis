## ============================================================
## RQ1 - Global and local spatial autocorrelation
## Tourism demand (overnight stays) across Italian municipalities
## ============================================================
## Required packages:
##   install.packages(c("sf", "spdep", "dplyr", "readr", "ggplot2",
##                       "classInt", "tmap", "stringr"))
## ============================================================

library(sf)        # spatial data handling (municipality boundary shapefile)
library(spdep)      # spatial weight matrices, Moran's I, LISA
library(dplyr)
library(readr)
library(ggplot2)
library(classInt)   # LISA quadrant classification
library(stringr)

## ------------------------------------------------------------
## 0. DATA IMPORT
## ------------------------------------------------------------

## Tabular data (tourism variables by municipality)
df <- read_csv("data/tourism_final_dataset.csv",
               col_types = cols(
                 province_code    = col_character(),
                 municipality_id  = col_character()
               ))

## NOTE: municipality_id must always have 6 digits (ISTAT PRO_COM format), preserving leading zeros as a character string.
df <- df %>%
  mutate(municipality_id = str_pad(municipality_id, width = 6, pad = "0"))

## Municipality administrative boundaries (ISTAT boundary shapefile).
comuni_sf <- st_read("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp", quiet = TRUE)

## In the ISTAT shapefile the municipality code is typically stored in a field called PRO_COM (or COD_ISTAT, depending on the release).
## Check the exact field name with: names(comuni_sf)
comuni_sf <- comuni_sf %>%
  mutate(municipality_id = str_pad(as.character(PRO_COM), width = 6, pad = "0"))

## ------------------------------------------------------------
## 1. MERGE TABULAR DATA + GEOMETRIES
## ------------------------------------------------------------

map_data <- comuni_sf %>%
  inner_join(df, by = "municipality_id")

cat("Municipalities in the tabular dataset: ", nrow(df), "\n")
cat("Municipalities with available geometry after the merge: ", nrow(map_data), "\n")
## If the row count drops a lot, check for unmatched codes with: setdiff(df$municipality_id, comuni_sf$municipality_id)

## Remove municipalities with missing or invalid geometry
map_data <- map_data %>%
  filter(!st_is_empty(geometry)) %>%
  st_make_valid()

## ------------------------------------------------------------
## 2. TRANSFORMATION OF THE VARIABLE OF INTEREST
## ------------------------------------------------------------

map_data <- map_data %>%
  mutate(log_stays = log(1 + total_overnight_stays))

## ------------------------------------------------------------
## 3. CONSTRUCTION OF THE SPATIAL WEIGHT MATRIX W
## ------------------------------------------------------------

## --- 3.1 Contiguity criterion (queen) ---
nb_queen <- poly2nb(map_data, queen = TRUE)

## Check for isolated municipalities (no neighbours under the queen criterion)
n_isolated <- sum(card(nb_queen) == 0)
cat("Municipalities with no neighbours (queen contiguity):", n_isolated, "\n")

## For island/isolated municipalities with no contiguous neighbours, link them to their nearest municipality (k = 1, straight-line distance)
## before proceeding, to avoid empty rows in the W matrix:
if (n_isolated > 0) {
  coords <- st_coordinates(st_centroid(st_geometry(map_data)))
  nb_knn1 <- knn2nb(knearneigh(coords, k = 1))
  nb_queen <- union.nb(nb_queen, nb_knn1)
}

listw_queen <- nb2listw(nb_queen, style = "W", zero.policy = TRUE)

## --- 3.2 k-nearest neighbours criterion (for the robustness check) ---
coords <- st_coordinates(st_centroid(st_geometry(map_data)))

k_values <- c(4, 6, 8)  # different k specifications to compare
listw_knn_list <- lapply(k_values, function(k) {
  nb_k <- knn2nb(knearneigh(coords, k = k))
  nb2listw(nb_k, style = "W", zero.policy = TRUE)
})
names(listw_knn_list) <- paste0("knn", k_values)

## ------------------------------------------------------------
## 4. GLOBAL MORAN'S I
## ------------------------------------------------------------

## --- 4.1 Test under the randomisation assumption (default) ---
moran_rand <- moran.test(map_data$log_stays, listw_queen,
                         zero.policy = TRUE,
                         randomisation = TRUE,
                         alternative = "greater")
print(moran_rand)

## --- 4.2 Test under the normality assumption ---
moran_norm <- moran.test(map_data$log_stays, listw_queen,
                         zero.policy = TRUE,
                         randomisation = FALSE,
                         alternative = "greater")
print(moran_norm)

## --- 4.3 Monte Carlo permutation test (non-parametric alternative) ---
set.seed(123)
moran_mc <- moran.mc(map_data$log_stays, listw_queen,
                     nsim = 999,
                     zero.policy = TRUE,
                     alternative = "greater")
print(moran_mc)
plot(moran_mc, main = "Moran's I - reference distribution (permutations)")

## ------------------------------------------------------------
## 5. MORAN SCATTERPLOT
## ------------------------------------------------------------

png("analysis/RQ-1/moran_scatterplot.png", width = 1400, height = 1100, res = 150)
mp <- moran.plot(map_data$log_stays, listw_queen,
                 zero.policy = TRUE,
                 xlab = "log(1 + overnight stays)",
                 ylab = "spatial lag of log(1 + overnight stays)",
                 main = "Moran scatterplot - tourism overnight stays")
dev.off()

## Identification of the most influential municipalities (returned by moran.plot)
influential_units <- map_data$municipality_name[mp$is_inf]
print(influential_units)

## ------------------------------------------------------------
## 6. LOCAL MORAN'S I (LISA)
## ------------------------------------------------------------

lisa <- localmoran(map_data$log_stays, listw_queen, zero.policy = TRUE)
colnames(lisa) <- c("Ii", "E.Ii", "Var.Ii", "Z.Ii", "Pr_Z")

map_data <- map_data %>%
  mutate(
    lisa_Ii   = lisa[, "Ii"],
    lisa_pval = lisa[, "Pr_Z"]
  )

## --- 6.1 Classification into the four quadrants (High-High, Low-Low, etc.) ---
x  <- map_data$log_stays
xz <- (x - mean(x)) / sd(x)                                  # standardised
wx <- lag.listw(listw_queen, x, zero.policy = TRUE)
wxz <- (wx - mean(wx)) / sd(wx)

alpha <- 0.05
map_data <- map_data %>%
  mutate(
    quadrant = case_when(
      lisa_pval > alpha            ~ "Not significant",
      xz >=  0 & wxz >=  0         ~ "High-High",
      xz <   0 & wxz <   0         ~ "Low-Low",
      xz >=  0 & wxz <   0         ~ "High-Low",
      xz <   0 & wxz >=  0         ~ "Low-High"
    ),
    quadrant = factor(quadrant,
                      levels = c("High-High", "Low-Low",
                                 "High-Low", "Low-High",
                                 "Not significant"))
  )

table(map_data$quadrant)

## --- 6.2 LISA cluster map ---
lisa_colors <- c("High-High" = "#d7191c",
                 "Low-Low"   = "#2c7bb6",
                 "High-Low"  = "#fdae61",
                 "Low-High"  = "#abd9e9",
                 "Not significant" = "grey90")

ggplot(map_data) +
  geom_sf(aes(fill = quadrant), color = "white", linewidth = 0.05) +
  scale_fill_manual(values = lisa_colors, name = "LISA cluster") +
  labs(title = "Local Moran's I (LISA) - tourism overnight stays",
       subtitle = paste0("Italian municipalities; W = queen contiguity; alpha = ", alpha)) +
  theme_minimal()

ggsave("analysis/RQ-1/lisa_map.png", width = 9, height = 9, dpi = 200)

## ------------------------------------------------------------
## 7. ROBUSTNESS CHECK: COMPARISON ACROSS DIFFERENT W SPECIFICATIONS
## ------------------------------------------------------------

robustness_results <- lapply(names(listw_knn_list), function(nm) {
  lw <- listw_knn_list[[nm]]
  mt <- moran.test(map_data$log_stays, lw, zero.policy = TRUE,
                   alternative = "greater")
  data.frame(
    W_specification = nm,
    Morans_I        = unname(mt$estimate["Moran I statistic"]),
    Expectation     = unname(mt$estimate["Expectation"]),
    Variance        = unname(mt$estimate["Variance"]),
    z_value         = unname(mt$statistic),
    p_value         = mt$p.value
  )
})

## Also add the result obtained with the queen W matrix as a benchmark
robustness_results[["queen"]] <- data.frame(
  W_specification = "queen",
  Morans_I        = unname(moran_rand$estimate["Moran I statistic"]),
  Expectation     = unname(moran_rand$estimate["Expectation"]),
  Variance        = unname(moran_rand$estimate["Variance"]),
  z_value         = unname(moran_rand$statistic),
  p_value         = moran_rand$p.value
)

robustness_table <- do.call(rbind, robustness_results)
print(robustness_table)

write_csv(robustness_table, "moran_robustness_table.csv")

## ------------------------------------------------------------
## 8. SUMMARY OUTPUT
## ------------------------------------------------------------

cat("\n==================== RQ1 SUMMARY ====================\n")
cat("Moran's I (queen, randomisation):", round(moran_rand$estimate[1], 4),
    " | p-value:", format.pval(moran_rand$p.value), "\n")
cat("Moran's I (MC permutation, 999 simulations): p-value:",
    format.pval(moran_mc$p.value), "\n")
cat("Significant LISA quadrants (alpha = 0.05):\n")
print(table(map_data$quadrant[map_data$quadrant != "Not significant"]))
cat("=======================================================\n")