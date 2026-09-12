# =============================================================================
# load_uci_data.R
# =============================================================================
library(data.table)
library(lubridate)

RAW_PATH <- "data/household_power_consumption.txt"

if (!file.exists(RAW_PATH)) {
  stop(
    "Couldn't find ", RAW_PATH, ".\n\n",
    "Download it from:\n",
    "  https://archive.ics.uci.edu/dataset/235/individual+household+electric+power+consumption\n",
    "Click 'Download', unzip the file, and place household_power_consumption.txt\n",
    "inside this project's data/ folder, then re-run this script."
  )
}

message("Reading raw UCI data (~127MB / ~2.07M rows) -- this can take under a minute...")

raw <- fread(
  RAW_PATH,
  sep = ";",
  na.strings = "?",
  colClasses = "character",
  showProgress = TRUE
)

raw[, timestamp := dmy_hms(paste(Date, Time))]
raw <- raw[!is.na(timestamp)]

num_cols <- c("Global_active_power", "Sub_metering_1", "Sub_metering_2", "Sub_metering_3")
raw[, (num_cols) := lapply(.SD, as.numeric), .SDcols = num_cols]

raw[, hour_bucket := floor_date(timestamp, "hour")]

hourly <- raw[, .(
  kitchen_wh  = sum(Sub_metering_1, na.rm = TRUE),
  laundry_wh  = sum(Sub_metering_2, na.rm = TRUE),
  water_ac_wh = sum(Sub_metering_3, na.rm = TRUE),
  global_wh   = sum(Global_active_power * 1000 / 60, na.rm = TRUE),
  n_minutes   = .N
), by = hour_bucket]

hourly <- hourly[n_minutes >= 55]
hourly[, other_wh := pmax(0, global_wh - kitchen_wh - laundry_wh - water_ac_wh)]

energy_long <- rbindlist(list(
  hourly[, .(building_id = "Kitchen",          timestamp = hour_bucket, consumption_kwh = kitchen_wh  / 1000)],
  hourly[, .(building_id = "Laundry Room",      timestamp = hour_bucket, consumption_kwh = laundry_wh  / 1000)],
  hourly[, .(building_id = "Water Heater & AC", timestamp = hour_bucket, consumption_kwh = water_ac_wh / 1000)],
  hourly[, .(building_id = "Other Appliances",  timestamp = hour_bucket, consumption_kwh = other_wh    / 1000)]
))

energy_long <- energy_long[order(building_id, timestamp)]
energy_long <- energy_long[consumption_kwh >= 0 & consumption_kwh < 50]

dir.create("data", showWarnings = FALSE)
fwrite(energy_long, "data/energy_data.csv")

message(sprintf(
  "Wrote %s rows across %d circuits (%s to %s) -> data/energy_data.csv",
  format(nrow(energy_long), big.mark = ","),
  uniqueN(energy_long$building_id),
  format(min(energy_long$timestamp)),
  format(max(energy_long$timestamp))
))
