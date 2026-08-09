library(sf)
library(spdep)
library(dplyr)
library(readr)
library(ggplot2)
library(stringr)

## 1. IMPORT E MERGE ------------------------------------------------
df <- read_csv("data/tourism_final_dataset.csv",
               col_types = cols(province_code = col_character(),
                                municipality_id = col_character())) %>%
  mutate(municipality_id = str_pad(municipality_id, 6, pad = "0"))

comuni_sf <- st_read("data/input/ISTAT/Com01012024_g/Com01012024_g_WGS84.shp", quiet = TRUE) %>%
  mutate(municipality_id = str_pad(as.character(PRO_COM), 6, pad = "0"))

map_data <- comuni_sf %>%
  inner_join(df, by = "municipality_id") %>%
  filter(!st_is_empty(geometry)) %>%
  st_make_valid() %>%
  mutate(log_stays = log(1 + total_overnight_stays))

## 2. MATRICE DI PESI SPAZIALI (queen contiguity) --------------------
nb_queen <- poly2nb(map_data, queen = TRUE)

if (sum(card(nb_queen) == 0) > 0) {
  coords <- st_coordinates(st_centroid(st_geometry(map_data)))
  nb_queen <- union.nb(nb_queen, knn2nb(knearneigh(coords, k = 1)))
}

listw_queen <- nb2listw(nb_queen, style = "W", zero.policy = TRUE)

## 3. MORAN'S I GLOBALE -----------------------------------------------
moran_rand <- moran.test(map_data$log_stays, listw_queen,
                         zero.policy = TRUE, alternative = "greater")

set.seed(123)
moran_mc <- moran.mc(map_data$log_stays, listw_queen,
                     nsim = 999, zero.policy = TRUE, alternative = "greater")

global_moran_table <- data.frame(
  Test = c("Moran's I (randomisation)", "Moran's I (Monte Carlo, 999 perm.)"),
  Statistic = c(moran_rand$estimate["Moran I statistic"], moran_mc$statistic),
  p_value = c(moran_rand$p.value, moran_mc$p.value)
)
global_moran_table

png("analysis/RQ-1/moran_scatterplot.png", width = 1400, height = 1100, res = 150)
moran.plot(map_data$log_stays, listw_queen, zero.policy = TRUE,
           xlab = "log(1 + overnight stays)",
           ylab = "spatial lag of log(1 + overnight stays)",
           main = "Moran scatterplot - tourism overnight stays")
dev.off()

## 4. LISA - CLUSTER LOCALI --------------------------------------------
lisa <- localmoran(map_data$log_stays, listw_queen, zero.policy = TRUE)
colnames(lisa) <- c("Ii", "E.Ii", "Var.Ii", "Z.Ii", "Pr_Z")

xz  <- scale(map_data$log_stays)[, 1]
wxz <- scale(lag.listw(listw_queen, map_data$log_stays, zero.policy = TRUE))[, 1]
alpha <- 0.05

map_data <- map_data %>%
  mutate(
    lisa_pval = lisa[, "Pr_Z"],
    quadrant = case_when(
      lisa_pval > alpha    ~ "Not significant",
      xz >= 0 & wxz >= 0    ~ "High-High",
      xz <  0 & wxz <  0    ~ "Low-Low",
      xz >= 0 & wxz <  0    ~ "High-Low",
      TRUE                  ~ "Low-High"
    ),
    quadrant = factor(quadrant, levels = c("High-High", "Low-Low",
                                           "High-Low", "Low-High",
                                           "Not significant"))
  )

lisa_table <- as.data.frame(table(map_data$quadrant))
names(lisa_table) <- c("Cluster", "N_municipalities")
lisa_table

lisa_colors <- c("High-High" = "#d7191c", "Low-Low" = "#2c7bb6",
                 "High-Low" = "#fdae61", "Low-High" = "#abd9e9",
                 "Not significant" = "grey90")

ggplot(map_data) +
  geom_sf(aes(fill = quadrant), color = "white", linewidth = 0.05) +
  scale_fill_manual(values = lisa_colors, name = "LISA cluster") +
  labs(title = "Local Moran's I (LISA) - tourism overnight stays",
       subtitle = paste0("W = queen contiguity; alpha = ", alpha)) +
  theme_minimal()

ggsave("analysis/RQ-1/lisa_map.png", width = 9, height = 9, dpi = 200)