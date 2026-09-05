# Italian Municipal Tourism Explorer — Usage Guide

An interactive Shiny web app for exploring tourism data, spatial spillover effects, and "what-if" scenarios across Italian municipalities.

> ⏳ **Please be patient.** Each interaction (switching tabs, selecting a variable, moving a municipality, dragging the slider) triggers a recalculation over the full national dataset and spatial weights matrix. The map may take a few seconds to update after every action — **wait for it to finish loading before clicking again**, rather than clicking repeatedly.

---

## Tab 1 — Night Stays

Explore the raw distribution of any variable in the dataset (overnight stays, beds, coastline, museums, sports facilities, UNESCO sites, altitude zone, etc.) across all Italian municipalities.

- Choose a variable from the dropdown to recolor the map.
- Click on any municipality to open a popup with its full profile (all variables at once).
- Numeric variables are shown on a logarithmic color scale; categorical variables (e.g. Altitude zone) use a qualitative palette.

---

## Tab 2 — Spillover

Visualize estimated **spatial spillover effects**: how a resource in a municipality's neighbors (hotel beds, sports facilities, nature-based activities, transport points, coastline, protected areas, etc.) affects that municipality's own overnight stays, based on the fitted Spatial Durbin Model (SDM).

- Choose a spillover variable from the dropdown.
- The sidebar shows the **overall network-wide effect** (direct / indirect / total, with significance) for cross-checking.
- Colors on the map show each municipality's estimated spillover effect (red/blue = negative/positive, i.e. competitive vs. complementary effect).
- Click a municipality to see its own popup: its actual value, its neighbors' average, and the resulting % change in overnight stays.

---

## Tab 3 — What-If

Simulate a change in one resource for a single municipality and see the predicted ripple effect on overnight stays across the **entire country** (not just direct neighbors), based on the spatial model's implied feedback loops.

**How to use it:**
1. Search for and select a municipality (or click one directly on the map).
2. Choose the resource to simulate (e.g. hotel beds, sports facilities, coastline km).
3. Move the slider to set a target value — it starts at the municipality's real current value; 0 removes the resource entirely, and the max is double its current value.
4. The map recolors to show the predicted overnight stays for every municipality under this scenario:
   - **Black border** = the selected municipality
   - **Blue border** = its direct neighbors
5. Two tables below the sidebar update automatically:
   - The selected municipality's own before/after change
   - The **top 10 municipalities** most affected by the change (ranked by % change), flagging whether each is a direct neighbor

> Because the what-if simulation solves a full spatial feedback system across all municipalities, this tab is the slowest to update — **wait for the map and tables to refresh fully before making another change.**

---

## General Tips

- Use the search box in the What-If tab instead of scrolling the map to quickly locate a specific municipality.
- Regional boundaries (dashed dark lines) are shown on all maps for geographic reference.
- All monetary/count values in popups and tables are formatted with thousands separators for readability.