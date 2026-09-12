# =============================================================================
# generate_data.R
# -----------------------------------------------------------------------------
# Creates a realistic synthetic hourly electricity-consumption dataset for
# PowerPulse to analyze. Run this once to produce data/energy_data.csv.
#
# If you already have your own dataset, skip this script entirely -- just
# make sure your CSV has these columns (any extra columns are ignored):
#
#   building_id   <chr>   e.g. "Building A"
#   timestamp     <POSIXct / parseable datetime>  hourly readings
#   consumption_kwh <dbl> energy used in that hour, in kWh
#
# and point app.R at it (see DATA_PATH in app.R).
# =============================================================================

library(dplyr)
library(lubridate)
library(purrr)

set.seed(42)

generate_building_profile <- function(building_id,
                                        start_date,
                                        n_days,
                                        base_load,
                                        morning_peak_mult,
                                        afternoon_peak_mult,
                                        weekend_mult,
                                        noise_sd,
                                        n_spikes = 3,
                                        n_drops = 2,
                                        n_night_anomalies = 2) {

  timestamps <- seq(as_datetime(start_date), by = "hour", length.out = n_days * 24)

  df <- tibble(
    building_id = building_id,
    timestamp   = timestamps
  ) %>%
    mutate(
      date       = as_date(timestamp),
      hour       = hour(timestamp),
      wday_num   = wday(timestamp, week_start = 1),      # 1 = Monday ... 7 = Sunday
      is_weekend = wday_num %in% c(6, 7),
      day_index  = as.integer(date - min(date))
    )

  # ---- Shape function: a "typical day" load curve (0-1 scale) --------------
  # Morning ramp (6-9), midday plateau, afternoon/HVAC peak (13-17), evening
  # decline, low overnight baseline. This is the *expected* physical shape.
  day_shape <- function(hr, weekend) {
    shape <- 0.25 +                                                             # night-time floor
      0.40 * morning_peak_mult   * dnorm(hr, mean = 8,  sd = 1.6) / dnorm(8, 8, 1.6)  + # morning ramp
      0.45 * afternoon_peak_mult * dnorm(hr, mean = 14, sd = 2.6) / dnorm(14, 14, 2.6) + # afternoon/HVAC peak
      0.35 * dnorm(hr, mean = 19, sd = 1.8) / dnorm(19, 19, 1.8)                        # evening bump
    if (weekend) shape <- shape * weekend_mult
    shape
  }

  # slow seasonal drift across the period (e.g. warming trend -> more HVAC)
  seasonal <- function(day_idx) 1 + 0.12 * sin(2 * pi * day_idx / n_days)

  df <- df %>%
    rowwise() %>%
    mutate(
      expected_shape = day_shape(hour, is_weekend),
      seasonal_mult  = seasonal(day_index),
      mean_kwh       = base_load * expected_shape * seasonal_mult,
      consumption_kwh = pmax(0, rnorm(1, mean = mean_kwh, sd = noise_sd))
    ) %>%
    ungroup() %>%
    select(-expected_shape, -seasonal_mult)

  # ---- Inject realistic anomalies for demo purposes -------------------------
  # These are NOT tagged for the detection engine -- it must find them on its
  # own from the statistics, exactly like a real deployment would have to.
  anomaly_days <- sample(unique(df$date)[8:(n_days - 3)],
                          n_spikes + n_drops + n_night_anomalies)

  spike_days <- anomaly_days[seq_len(n_spikes)]
  drop_days  <- anomaly_days[(n_spikes + 1):(n_spikes + n_drops)]
  night_days <- anomaly_days[(n_spikes + n_drops + 1):length(anomaly_days)]

  for (d in spike_days) {
    hrs <- sample(6:17, sample(2:4, 1))
    idx <- df$date == d & df$hour %in% hrs
    df$consumption_kwh[idx] <- df$consumption_kwh[idx] * runif(sum(idx), 1.6, 2.4)
  }

  for (d in drop_days) {
    hrs <- sample(8:18, sample(2:4, 1))
    idx <- df$date == d & df$hour %in% hrs
    df$consumption_kwh[idx] <- df$consumption_kwh[idx] * runif(sum(idx), 0.25, 0.5)
  }

  for (d in night_days) {
    hrs <- sample(0:5, sample(2:3, 1))
    idx <- df$date == d & df$hour %in% hrs
    df$consumption_kwh[idx] <- df$consumption_kwh[idx] * runif(sum(idx), 2.2, 3.5) + 15
  }

  df %>% select(building_id, timestamp, date, hour, wday_num, is_weekend, consumption_kwh)
}

buildings <- list(
  list(id = "Building A", base_load = 28, morning = 1.4, afternoon = 1.8, weekend = 0.65, noise = 3.2),
  list(id = "Building B", base_load = 19, morning = 1.3, afternoon = 1.5, weekend = 0.55, noise = 2.4),
  list(id = "Building C", base_load = 34, morning = 1.5, afternoon = 2.0, weekend = 0.70, noise = 4.0)
)

N_DAYS     <- 90
START_DATE <- Sys.Date() - N_DAYS

energy_data <- map_dfr(buildings, function(b) {
  generate_building_profile(
    building_id         = b$id,
    start_date           = START_DATE,
    n_days               = N_DAYS,
    base_load            = b$base_load,
    morning_peak_mult    = b$morning,
    afternoon_peak_mult  = b$afternoon,
    weekend_mult         = b$weekend,
    noise_sd             = b$noise
  )
})

dir.create("data", showWarnings = FALSE)
readr::write_csv(energy_data, "data/energy_data.csv")

message(sprintf(
  "Generated %d rows across %d buildings (%d days each) -> data/energy_data.csv",
  nrow(energy_data), length(buildings), N_DAYS
))
