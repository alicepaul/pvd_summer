# Install relevant libraries ---------------------------------------------------
library(geosphere)
library(ggplot2)
library(sf)
library(tidyverse)
library(tigris)
library(kernlab)

# Import relevant functions ----------------------------------------------------
path <- "./scooterData/"
source(paste(path, "clusterSpectralEvaluate.R", sep = ""))

# Set clustering parameters ----------------------------------------------------
numGeo <- 10 # Number of groups to create in geographic clustering
numUsage <- 8 # Number of groups to create in usage pattern clustering
neighbors <- 8 # Number of neighboring nodes to based relabeling off of 

seed <- 126 # Set random seed based on clusterSpectralDetermineRandom.R
# seed <- 2
set.seed(seed)

# Import trip data -------------------------------------------------------------
# dir <- "/home/marion/PVDResearch/Data/mobilityData/cleanData"
# dir <- "/Users/Alice/Documents"
dir <- "/Users/nolan/Documents"
filename <- "tripsYear1WithTracts"
path <- file.path(dir, paste(filename, ".csv", sep = ""))
assign(filename, read.csv(path))

# Import census tract data -----------------------------------------------------
# dir <- "/home/marion/PVDResearch/PVDResearch/censusData"
# dir <- "/Users/Alice/Dropbox/pvd_summer/censusData"
dir <- "./censusData"
filename <- "riData"
path <- file.path(dir, paste(filename, ".csv", sep = ""))
assign(filename, read.csv(path))

# Clean and filter trip data ---------------------------------------------------
cleanData <- function(data, start_date, end_date) {
  data <- data %>%
    # Consider only trips that last at least 3 minutes
    filter(minutes >= 3) %>% 
    # Select time range
    mutate(start_time = as.POSIXct(start_time, tz = "EST")) %>%
    filter(start_time > start_date & start_time < end_date) %>%
    # Round coordinates to the nearest 5/1000 place
    mutate(start_lat = 0.005*round(start_latitude/0.005, digits = 0),
           start_long = 0.005*round(start_longitude/0.005, digits = 0),
           end_lat = 0.005*round(end_latitude/0.005, digits = 0),
           end_long = 0.005*round(end_longitude/0.005, digits = 0),
           from = paste("(", start_lat, ", ", start_long, ")", sep = ""),
           to = paste("(", end_lat, ", ", end_long, ")", sep = "")) %>%
    # Consider only trips that occurred at least 5 times 
    group_by(from, to) %>%
    summarise(start_lat = mean(start_lat), 
              start_long = mean(start_long),
              end_lat = mean(end_lat),
              end_long = mean(end_long),
              count = n()) %>%
    filter(count >= 5)
  return(data)
}

dataYear <- cleanData(tripsYear1WithTracts, start_date = "2018-10-17", end_date = "2019-09-19")

# Use spectral clustering to group by geographic information -------------------
numNodes <- function(data) {
  # Count number of nodes per cluster
  numNodes <- data %>%
    group_by(sc) %>%
    summarise(count = n()) 
  return(numNodes$count)
}

clusterByGeo <- function(data, numClusters) {
  # Summarize data by geographic information for clustering
  data <- data %>%
    group_by(from) %>%
    summarise(start_lat = mean(start_lat), 
              start_long = mean(start_long)) %>%
    select(start_lat, start_long)
  # Create groups using spectral clustering
  sc <- specc(as.matrix(data), centers = numClusters)
  data <- data %>% 
    mutate(from = paste("(", start_lat, ", ", start_long, ")", sep = ""), 
           sc = as.factor(sc)) 
  # Count number of nodes per cluster
  numNodes <- numNodes(data)
  # Calculate intra-cluster similarity based on geographic information
  clustersGeo <- data %>% 
    select(start_long, start_lat, sc)
  sim <- round(avgSim(clustersGeo, numClusters), digits = 3)
  return(list(clusters = data, numNodes = numNodes, sim = sim))
}

geoYear <- clusterByGeo(dataYear, numGeo)

# Use spectral clustering to group by usage pattern ----------------------------
calculateUsage <- function(data, geoData) {
  # Map trip data to geographic clusters
  data$end_sc <- NA
  for (i in 1:nrow(geoData)) {
    coord <- geoData[i,]$from
    sc <- geoData[i,]$sc
    ind <- which(data$to == coord)
    data$end_sc[ind] <- sc
  } 
  # Remove trips whose end coordinates do not correspond to a geographic cluster
  data <- data[!is.na(data$end_sc),]
  # Count number of scooters that travel from each start coordinate to each cluster
  data <- data %>%
    group_by(from, end_sc) %>%
    summarise(start_lat = mean(start_lat), 
              start_long = mean(start_long), 
              count = n()) %>%
    spread(end_sc, count)
  # Replace NA values with 0
  data[is.na(data)] <- 0
  # Convert scooter counts to proportions
  data[-1:-3] <- round(data[-1:-3] / rowSums(data[-1:-3]), digits = 2)
  return(data)
}

clusterByUsage <- function(data, geoData, numClusters) {
  # Summarize data by usage pattern for clustering
  usageData <- calculateUsage(data, geoData) 
  data <- usageData %>%
    ungroup() %>%
    select(-c(from, start_long, start_lat))
  # Create groups using spectral clustering
  sc <- specc(as.matrix(data), centers = numClusters)
  data <- data %>% 
    mutate(start_lat = usageData$start_lat,
           start_long = usageData$start_long,
           from = paste("(", start_lat, ", ", start_long, ")", sep = ""),
           sc = as.factor(sc))
  # Count number of nodes per cluster
  numNodes <- numNodes(data)
  # Calculate intra-cluster similarity based on usage pattern
  clustersUsage <- data %>% 
    select(-c(start_lat, start_long, from))
  sim <- round(avgSim(clustersUsage, numClusters), digits = 3)
  return(list(clusters = data, numNodes = numNodes, sim = sim))
}

usageYear <- clusterByUsage(dataYear, geoYear$clusters, numUsage)

# Adjust pattern clustering result to obtain numGeo clusters -------------------
splitClusters <- function(data, numGeo, numUsage) {
  # Keep for later use
  original <- data$clusters
  for (i in 1:(numGeo-numUsage)) {
    # Find biggest cluster in pattern clustering result
    max <- which.max(data$numNodes)
    clusterData <- data$clusters %>%
      filter(sc == max) 
    # Use spectral clustering to split it into two based on geographical information
    clusterData <- clusterByGeo(clusterData, 2)
    # Combine clustering result with the original pattern clustering result
    clusterData <- clusterData$clusters
    clusterData$sc <- as.character(clusterData$sc)
    clusterData$sc[clusterData$sc == "2"] <- length(data$numNodes)+1
    clusterData$sc[clusterData$sc == "1"] <- max
    clusterData <- clusterData %>%
      mutate(from = paste("(", start_lat, ", ", start_long, ")", sep = "")) %>%
      select(start_lat, start_long, from, sc)
    data <- data$clusters %>%
      filter(sc != max) %>%
      select(start_lat, start_long, from, sc)
    data <- rbind(data, clusterData)
    # Count number of nodes per cluster
    numNodes <- numNodes(data)
    # Replace original pattern clustering result with new clustering result
    data <- (list(clusters = data, numNodes = numNodes))
  } 
  # Merge usage pattern data with cluster data for similarity calculation
  data$clusters <- merge(data$clusters, 
                         select(original, -c(start_lat, start_long, sc)), 
                         by = "from")
  # Calculate intra-cluster similarity based on usage pattern
  clustersUsage <- data$clusters %>% 
    select(-c(start_lat, start_long, from))
  sim <- round(avgSim(clustersUsage, numGeo), digits = 3)
  return(list(clusters = data$clusters, numNodes = data$numNodes, sim = sim))
}

splitYear <- splitClusters(usageYear, numGeo, numUsage)

# Use LPA to make clustering result more reasonable ----------------------------
mode <- function(x) {
  # Calculate mode of a set of data
  ux <- unique(x)
  return(ux[which.max(tabulate(match(x, ux)))])
}

handleOutliers <- function(data, numNodes, distMatrix, neighbors) {
  # Find outliers 
  outliers <- which(numNodes <= 2)
  # If outliers exist, 
  if (length(outliers) > 0) {
    # Loop through each outlier cluster
    for (k in 1:length(outliers)) {
      # Loop through each node in the outlier cluster
      outlierNodes <- which(data$sc == outliers[k])
      for (l in 1:length(outlierNodes)) {
        # Determine 8 nearest nodes (neighbors)
        ind <- sort(distMatrix[,outlierNodes[l]], na.last = TRUE, index.return = TRUE)$ix
        ind <- ind[1:neighbors] 
        # Get neighbor node cluster labels
        neighborClusters <- unique(data$sc[ind]) 
        neighborClusters <- neighborClusters[neighborClusters != outliers[k]]
        # Loop through each neighbor cluster
        sim <- 1
        bestCluster <- outliers[k]
        for (m in 1:length(neighborClusters)) {
          # Add outlier node to neighbor cluster
          newData <- data
          newData$sc[outlierNodes[l]] <- neighborClusters[m]
          # Calculate intra-cluster similarity based on usage pattern
          newSim <- calculateSim(newData, neighborClusters[m])
          # Store clustering result only if similarity value is less than all previous similarity values
          if (newSim < sim) {
            sim <- newSim
            bestCluster <- neighborClusters[m]
          }
        }
        # Group outlier node with best nearby cluster based on usage pattern
        data$sc[outlierNodes[l]] <- bestCluster
      } 
    }
  }
  return(data)
}

relabelClusters <- function(data, numGeo, neighbors) {
  # Create distance matrix from coordinate nodes
  coord <- data$clusters %>%
    select(start_long, start_lat)
  dist <- as.data.frame(distm(coord, coord, distGeo))
  dist[dist == 0] <- NA
  # Initialize data frame to hold relabeled data
  relabeledData <- data$clusters
  # Loop through each coordinate node
  for (i in 1:nrow(data$clusters)) {
    # Determine 8 nearest nodes (neighbors)
    ind <- sort(dist[,i], na.last = TRUE, index.return = TRUE)$ix
    ind <- ind[1:neighbors] 
    # Get neighbor node data
    neighborClusters <- data$clusters[ind,]
    neighborDist <- round(dist[ind,i])
    totalNeighborDistances <- numeric(10)
    # Create vector of neighbor node clusters such that frequency corresponds to the distance of that neighbor to the chosen coordinate node
    # neighborNodes <- c()
    for (j in 1:neighbors) {
      # neighborNodes <- c(neighborNodes, rep.int(c(neighborClusters$sc[j]), neighborDist[j]))
      totalNeighborDistances[neighborClusters$sc[j]] <- totalNeighborDistances[neighborClusters$sc[j]] + 1/neighborDist[j]
    }
    # print(totalNeighborDistances)
    # print(neighborNodes)
    # Determine most common cluster label of neighbors
    # cluster <- mode(neighborNodes)
    cluster <- which.max(totalNeighborDistances)
    if (as.integer(tail(table(totalNeighborDistances), n=1)) == 1) {
      relabeledData$sc[i] <- as.numeric(cluster)
    }
    # print(which.max(totalNeighborDistances))
    # Relabel selected node based on neighbors
    # relabeledData$sc[i] <- as.numeric(cluster)
  }
  # Count number of nodes per cluster
  numNodes <- numNodes(relabeledData)
  # Relabel clusters in case some labels were lost in relabeling process
  # if (length(numNodes) < numGeo) {
    relabeledData$sc <- factor(relabeledData$sc, labels = 1:length(numNodes))
  # }
  # Group outliers in with cluster most similar based on usage pattern
  # relabeledData <- handleOutliers(relabeledData, numNodes, dist, neighbors)
  # Recount number of nodes per cluster
  numNodes <- numNodes(relabeledData)
  # Calculate intra-cluster similarity based on usage pattern
  clustersUsage <- relabeledData %>% 
    select(-c(start_lat, start_long, from))
  sim <- round(avgSim(clustersUsage, numGeo), digits = 3)
  return(list(clusters = relabeledData, numNodes = numNodes, sim = sim))
}

relabelYear <- relabelClusters(splitYear, numGeo, neighbors)

# Plot clusters ----------------------------------------------------------------
createPlot <- function(data, title, numGeo, numUsage){
  # Get map of Providence County census tracts
  censusTracts <- tracts("RI", class = "sf") %>%
    select(GEOID) %>%
    filter(GEOID %in% riData$GEOID)
  # Plot clusters over map of census tracts
  # convex <- chull(data$clusters)
  # convex_points <- data$clusters[convex,]
  # print(class(convex_points))
  # convex <- data$clusters
  plot <- ggplot(censusTracts, group = data$clusters$sc) +
    geom_sf() +
    # Plot clusters
    geom_point(data = data$clusters, aes(x = start_long, y = start_lat, fill = as.factor(sc)), size = 2, shape = 21) + #Color clusters
    # Label plot
    scale_color_discrete(name = "Nodes per Cluster", labels = data$numNodes) +
    scale_fill_discrete(name = "Nodes per Cluster", labels = data$numNodes) +
    
    guides(color = guide_legend(ncol = 2)) +
    labs(title = title,
         subtitle = paste("numGeo =", numGeo, "and numUsage =", numUsage,
                          "\navgSimilarity =", data$sim,
                          "\nrandomSeed =", seed)) +
    # Remove gray background
    theme_bw() + 
    # Remove grid
    theme(panel.grid.major = element_blank(), panel.grid.minor = element_blank()) + 
    # Rotate x axis labels
    theme(axis.text.x = element_text(angle = 90))
    # geom_polygon(data = convex_points, aes(x = start_long, y = start_lat, color = as.factor(sc)), alpha = 0.5)
    for (i in levels(data$clusters$sc)){
      cluster <- data$clusters %>% filter(sc==i)
      convex <- chull(x = cluster$start_long, y = cluster$start_lat)
      convex_points <- cluster[convex,]
      # print(convex_points)
      # print(i)
      # print(as.factor(convex_points$sc))
      plot <- plot + geom_polygon(data = convex_points, aes(x = start_long, y = start_lat, fill = as.factor(sc)), color = "black", alpha = 0.5)
    }
  return(plot)
}

plotYearGeo <- createPlot(geoYear, "Spectral clustering by \ngeographical information", numGeo, numUsage)
plotYearUsage <- createPlot(usageYear, "Spectral clustering \nby usage pattern", numGeo, numUsage)
plotYearSplit <- createPlot(splitYear, "Usage pattern clustering split \nby geographical information", numGeo, numUsage)
plotYearLPA <- createPlot(relabelYear, "Clustering result after LPA", numGeo, numUsage)
# plotYearSplit
plotYearLPA
# Save plots -------------------------------------------------------------------

# plots <- mget(ls(pattern="plot"))
# dir <- "/home/marion/PVDResearch/Plots"
# # dir <- "/Users/Alice/Dropbox/pvd_summer"
# # dir <- "/Users/nolan/Dropbox/pvd_summer_plots"
# filenames <- c("Spectral_clusters_by_geo_10", 
#                "Spectral_cluster_after_LPA_10",
#                "Spectral_clusters_by_usage_split_10", 
#                "Spectral_clusters_by_usage_10")
# paths <- file.path(dir, paste(filenames, ".png", sep = ""))
# 
# for(i in 1:length(plots)){
#   invisible(mapply(ggsave, file = paths[i], plot = plots[i]))
# }
