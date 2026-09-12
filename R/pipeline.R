# =============================================================================
# pipeline.R
# -----------------------------------------------------------------------------
# The analytical engine behind PowerPulse. Pure functions, no Shiny code here,
# so you can source() this file and use it from a plain R script too.
#
# Pipeline stages (mirrors the architecture in the brief):
#   1. clean_energy_data()      -> Data Cleaning
#   2. profile_consumption()    -> Consumption Profiling
#   3. build_baseline()         -> Baseline Generation (dynamic, per hour/day-type)
#   4. detect_anomalies()       -> Anomaly Detection (z-score + IQR + deviation%)
#   5. score_severity()         -> Anomaly severity scoring (0-100 -> band)
#   6. explain_anomaly()        -> Statistical Explanation ("likely causes")
# =============================================================================

library(dplyr)
library(tidyr)
library(lubridate)
library(purrr)
library(stringr)

# -----------------------------------------------------------------------------
# 1. DATA CLEANING
# -----------------------------------------------------------------------------
#' Clean a raw energy dataset and add calendar/time features.
#'
#' @param df data.frame with building_id, timestamp, consumption_kwh
#' @return cleaned tibble with added time features
clean_energy_data <- function(df) {
  df %>%
    mutate(
      timestamp       = as_datetime(timestamp),
      building_id     = as.character(building_id),
      consumption_kwh = as.numeric(consumption_kwh)
    ) %>%
    # drop exact duplicate readings
    distinct(building_id, timestamp, .keep_all = TRUE) %>%
    # drop rows with no usable reading
    filter(!is.na(timestamp), !is.na(consumption_kwh)) %>%
    # clip physically impossible negative readings to 0
    mutate(consumption_kwh = pmax(consumption_kwh, 0)) %>%
    arrange(building_id, timestamp) %>%
    group_by(building_id) %>%
    # linear-interpolate small isolated gaps (<=2 consecutive missing hours)
    mutate(consumption_kwh = zoo_interp(consumption_kwh)) %>%
    ungroup() %>%
    mutate(
      date        = as_date(timestamp),
      hour        = hour(timestamp),
      wday_num    = wday(timestamp, week_start = 1),        # 1 Mon ... 7 Sun
      wday_label  = wday(timestamp, week_start = 1, label = TRUE, abbr = TRUE),
      is_weekend  = wday_num %in% c(6, 7),
      day_type    = if_else(is_weekend, "weekend", "weekday"),
      is_night    = hour %in% c(0, 1, 2, 3, 4, 5),
      month_lab   = month(timestamp, label = TRUE, abbr = TRUE),
      season      = case_when(
        month(timestamp) %in% c(12, 1, 2) ~ "Winter",
        month(timestamp) %in% c(3, 4, 5)  ~ "Spring",
        month(timestamp) %in% c(6, 7, 8)  ~ "Summer",
        TRUE                               ~ "Autumn"
      )
    )
}

# small helper: linear-interpolate NAs without requiring the `zoo` package
zoo_interp <- function(x) {
  if (!anyNA(x)) return(x)
  n <- length(x)
  idx <- seq_len(n)
  good <- !is.na(x)
  if (sum(good) < 2) return(x)
  approx(idx[good], x[good], xout = idx, rule = 2)$y
}

# -----------------------------------------------------------------------------
# 2. CONSUMPTION PROFILING
# -----------------------------------------------------------------------------
#' Build a set of summary profiles used both for display and for anomaly logic.
#'
#' @param df cleaned data (output of clean_energy_data)
#' @return a named list of tibbles: hourly, daily, weekly, peak_hours,
#'         weekday_vs_weekend, seasonal
profile_consumption <- function(df) {

  hourly <- df %>%
    group_by(building_id, hour) %>%
    summarise(avg_kwh = mean(consumption_kwh), .groups = "drop")

  daily <- df %>%
    group_by(building_id, date) %>%
    summarise(total_kwh = sum(consumption_kwh), .groups = "drop")

  weekly <- df %>%
    group_by(building_id, wday_label) %>%
    summarise(avg_kwh = mean(consumption_kwh), .groups = "drop")

  # peak hours = top quartile of average hourly consumption, per building
  peak_hours <- hourly %>%
    group_by(building_id) %>%
    mutate(threshold = quantile(avg_kwh, 0.75)) %>%
    filter(avg_kwh >= threshold) %>%
    summarise(peak_hours = list(sort(hour)), .groups = "drop")

  weekday_vs_weekend <- df %>%
    group_by(building_id, day_type) %>%
    summarise(avg_kwh = mean(consumption_kwh), .groups = "drop")

  seasonal <- df %>%
    group_by(building_id, season) %>%
    summarise(avg_kwh = mean(consumption_kwh), .groups = "drop")

  list(
    hourly              = hourly,
    daily               = daily,
    weekly              = weekly,
    peak_hours          = peak_hours,
    weekday_vs_weekend  = weekday_vs_weekend,
    seasonal            = seasonal
  )
}

# -----------------------------------------------------------------------------
# 3. DYNAMIC BASELINE
# -----------------------------------------------------------------------------
#' Build an "expected consumption" baseline per building / hour-of-day /
#' day-type (weekday vs weekend), using leave-one-day-out statistics so a
#' day's own anomalies can't distort its own expectation.
#'
#' This is what lets the system know that "Saturday 8 AM" and "Monday 8 AM"
#' are simply different regimes, rather than comparing everything to one
#' global number.
#'
#' @param df cleaned data
#' @param min_history minimum number of historical observations required
#'   before a baseline is considered reliable (falls back to the day-type
#'   average otherwise)
#' @return df joined with expected_mean, expected_sd, expected_q1, expected_q3
build_baseline <- function(df, min_history = 5) {

  stats_by_group <- df %>%
    group_by(building_id, hour, day_type) %>%
    summarise(
      n            = n(),
      group_mean   = mean(consumption_kwh),
      group_sd     = sd(consumption_kwh),
      group_q1     = quantile(consumption_kwh, 0.25),
      group_q3     = quantile(consumption_kwh, 0.75),
      .groups = "drop"
    )

  # Peak hours per building: the top quartile of average hourly load,
  # ignoring weekday/weekend split, so "peak-load" anomalies are judged
  # against hours that are *actually* busy for this specific building --
  # not a hardcoded clock-time guess.
  peak_flags <- df %>%
    group_by(building_id, hour) %>%
    summarise(hour_avg = mean(consumption_kwh), .groups = "drop") %>%
    group_by(building_id) %>%
    mutate(is_peak_hour = hour_avg >= quantile(hour_avg, 0.75)) %>%
    ungroup() %>%
    select(building_id, hour, is_peak_hour)

  # Overall per-building mean, used later as a scale reference so a tiny
  # absolute change on a near-zero-baseline circuit (e.g. a "kitchen" meter
  # that's usually ~0 kWh) doesn't register as a huge % anomaly.
  building_scale <- df %>%
    group_by(building_id) %>%
    summarise(building_mean_kwh = mean(consumption_kwh), .groups = "drop")

  df %>%
    group_by(building_id, hour, day_type) %>%
    mutate(
      # leave-one-out mean/sd within this (building, hour, day_type) cell
      n_cell        = n(),
      sum_cell      = sum(consumption_kwh),
      loo_mean_raw  = if_else(n_cell > 1,
                               (sum_cell - consumption_kwh) / (n_cell - 1),
                               NA_real_),
      loo_sd_raw    = { s <- sd(consumption_kwh); rep(s, n()) }
    ) %>%
    ungroup() %>%
    left_join(stats_by_group, by = c("building_id", "hour", "day_type")) %>%
    left_join(peak_flags, by = c("building_id", "hour")) %>%
    left_join(building_scale, by = "building_id") %>%
    mutate(
      expected_mean = if_else(!is.na(loo_mean_raw) & n_cell >= min_history,
                               loo_mean_raw, group_mean),
      expected_sd   = if_else(!is.na(loo_sd_raw) & loo_sd_raw > 0 & n_cell >= min_history,
                               loo_sd_raw, pmax(group_sd, 0.05 * group_mean, 1e-6)),
      expected_q1   = group_q1,
      expected_q3   = group_q3,
      expected_iqr  = expected_q3 - expected_q1
    ) %>%
    select(-n_cell, -sum_cell, -loo_mean_raw, -loo_sd_raw, -n, -group_mean, -group_sd, -group_q1, -group_q3)
}

# -----------------------------------------------------------------------------
# 3b. DAILY & WEEKLY ANOMALY DETECTION
# -----------------------------------------------------------------------------
# The hourly detector above answers "was this hour abnormal?". These two
# functions answer the same question at coarser resolutions -- "was this
# whole day abnormal?" and "was this whole week abnormal?" -- using the same
# leave-one-out baseline idea, just aggregated up first.

# shared scoring helpers so daily/weekly severity uses the same 0-100 scale
# and Normal/Low/Moderate/Critical bands as the hourly detector
simple_severity_score <- function(z_score, deviation_pct, is_anomaly) {
  z_component   <- pmin(abs(z_score) / 4, 1) * 60
  dev_component <- pmin(abs(deviation_pct) / 100, 1) * 40
  raw <- z_component + dev_component
  if_else(is_anomaly, pmin(100, round(raw)), pmin(20, round(raw)))
}

severity_band_from_score <- function(score) {
  case_when(
    score <= 20 ~ "Normal",
    score <= 40 ~ "Low",
    score <= 70 ~ "Moderate",
    TRUE        ~ "Critical"
  )
}

#' Detect whole-day consumption anomalies. Baseline is computed per
#' (building, day_type, season) using leave-one-day-out statistics, so a
#' summer Tuesday is compared against other summer Tuesdays -- not against
#' winter Tuesdays or weekends.
#'
#' @param df cleaned data (output of clean_energy_data)
#' @return one row per building/date with total_kwh, expected_total,
#'   z_score, deviation_pct, is_anomaly, anomaly_score, severity_band
detect_daily_anomalies <- function(df, z_thresh = 2, dev_thresh = 25, min_history = 4) {

  daily <- df %>%
    group_by(building_id, date, day_type, season, wday_label) %>%
    summarise(total_kwh = sum(consumption_kwh), .groups = "drop")

  building_scale <- daily %>%
    group_by(building_id) %>%
    summarise(building_daily_mean = mean(total_kwh), .groups = "drop")

  stats_by_group <- daily %>%
    group_by(building_id, day_type, season) %>%
    summarise(n = n(), group_mean = mean(total_kwh), group_sd = sd(total_kwh), .groups = "drop")

  daily %>%
    group_by(building_id, day_type, season) %>%
    mutate(
      n_cell       = n(),
      sum_cell     = sum(total_kwh),
      loo_mean_raw = if_else(n_cell > 1, (sum_cell - total_kwh) / (n_cell - 1), NA_real_),
      loo_sd_raw   = { s <- sd(total_kwh); rep(s, n()) }
    ) %>%
    ungroup() %>%
    left_join(stats_by_group, by = c("building_id", "day_type", "season")) %>%
    left_join(building_scale, by = "building_id") %>%
    mutate(
      expected_total = if_else(!is.na(loo_mean_raw) & n_cell >= min_history, loo_mean_raw, group_mean),
      expected_sd    = if_else(!is.na(loo_sd_raw) & loo_sd_raw > 0 & n_cell >= min_history,
                                loo_sd_raw, pmax(group_sd, 0.05 * group_mean, 1e-6)),
      z_score        = (total_kwh - expected_total) / expected_sd,
      deviation_pct  = 100 * (total_kwh - expected_total) / pmax(expected_total, 1e-6),
      min_abs_dev    = pmax(0.1, 0.05 * building_daily_mean),
      meaningful     = abs(total_kwh - expected_total) >= min_abs_dev,
      reliable_pct   = expected_total >= 0.15 * pmax(building_daily_mean, 1e-6),
      z_flag         = abs(z_score) >= z_thresh & meaningful,
      dev_flag       = abs(deviation_pct) >= dev_thresh & meaningful & reliable_pct,
      is_anomaly     = z_flag | dev_flag,
      direction      = if_else(total_kwh >= expected_total, "spike", "drop"),
      anomaly_score  = simple_severity_score(z_score, deviation_pct, is_anomaly),
      severity_band  = severity_band_from_score(anomaly_score)
    ) %>%
    select(building_id, date, day_type, season, wday_label, total_kwh,
           expected_total, expected_sd, z_score, deviation_pct,
           is_anomaly, direction, anomaly_score, severity_band)
}

#' Detect whole-week consumption anomalies. Baseline is each building's own
#' history of weekly totals (leave-one-week-out), requiring a nearly-complete
#' week of readings so partial weeks at the very start/end of the dataset
#' aren't unfairly compared against full weeks.
#'
#' @param df cleaned data (output of clean_energy_data)
#' @param min_hours minimum hours of data required within a week to score it
#' @return one row per building/ISO-week with total_kwh, expected_total,
#'   z_score, deviation_pct, is_anomaly, anomaly_score, severity_band
detect_weekly_anomalies <- function(df, z_thresh = 2, dev_thresh = 25, min_history = 4, min_hours = 120) {

  weekly <- df %>%
    mutate(iso_year = isoyear(timestamp), iso_week = isoweek(timestamp)) %>%
    group_by(building_id, iso_year, iso_week) %>%
    summarise(
      week_start = min(date),
      total_kwh  = sum(consumption_kwh),
      n_hours    = n(),
      .groups = "drop"
    ) %>%
    filter(n_hours >= min_hours)

  stats_by_building <- weekly %>%
    group_by(building_id) %>%
    summarise(n = n(), group_mean = mean(total_kwh), group_sd = sd(total_kwh), .groups = "drop")

  weekly %>%
    group_by(building_id) %>%
    mutate(
      n_cell       = n(),
      sum_cell     = sum(total_kwh),
      loo_mean_raw = if_else(n_cell > 1, (sum_cell - total_kwh) / (n_cell - 1), NA_real_),
      loo_sd_raw   = { s <- sd(total_kwh); rep(s, n()) }
    ) %>%
    ungroup() %>%
    left_join(stats_by_building, by = "building_id") %>%
    mutate(
      expected_total = if_else(!is.na(loo_mean_raw) & n_cell >= min_history, loo_mean_raw, group_mean),
      expected_sd    = if_else(!is.na(loo_sd_raw) & loo_sd_raw > 0 & n_cell >= min_history,
                                loo_sd_raw, pmax(group_sd, 0.05 * group_mean, 1e-6)),
      z_score        = (total_kwh - expected_total) / expected_sd,
      deviation_pct  = 100 * (total_kwh - expected_total) / pmax(expected_total, 1e-6),
      z_flag         = abs(z_score) >= z_thresh,
      dev_flag       = abs(deviation_pct) >= dev_thresh,
      is_anomaly     = z_flag | dev_flag,
      direction      = if_else(total_kwh >= expected_total, "spike", "drop"),
      anomaly_score  = simple_severity_score(z_score, deviation_pct, is_anomaly),
      severity_band  = severity_band_from_score(anomaly_score)
    ) %>%
    select(building_id, iso_year, iso_week, week_start, total_kwh,
           expected_total, expected_sd, z_score, deviation_pct,
           is_anomaly, direction, anomaly_score, severity_band)
}

#' Plain-English explanation for a scored daily row (see detect_daily_anomalies).
explain_daily_anomaly <- function(row) {
  if (!isTRUE(row$is_anomaly)) {
    return(sprintf("Total consumption on this %s was within the expected range for a %s %s in %s.",
                    row$wday_label, row$day_type, row$wday_label, row$season))
  }
  dir_word <- if (row$direction == "spike") "higher" else "lower"
  sprintf("Daily total was %.0f%% %s than expected for a %s %s in %s (%.1f\u03c3 %s expected level).",
          abs(row$deviation_pct), dir_word, row$day_type, row$wday_label, row$season,
          abs(row$z_score), if (row$direction == "spike") "above" else "below")
}

#' Plain-English explanation for a scored weekly row (see detect_weekly_anomalies).
explain_weekly_anomaly <- function(row) {
  if (!isTRUE(row$is_anomaly)) {
    return("Weekly total consumption was within this building's normal historical range.")
  }
  dir_word <- if (row$direction == "spike") "higher" else "lower"
  sprintf("Week of %s totaled %.0f%% %s than this building's typical week (%.1f\u03c3 %s expected level).",
          format(row$week_start, "%b %d, %Y"), abs(row$deviation_pct), dir_word,
          abs(row$z_score), if (row$direction == "spike") "above" else "below")
}

# -----------------------------------------------------------------------------
# 4. ANOMALY DETECTION
# -----------------------------------------------------------------------------
#' Flag anomalies using z-score, IQR fence, and % deviation from baseline.
#' Also flags "repeated pattern" anomalies (same hour anomalous on multiple
#' recent occurrences of the same day-type).
#'
#' @param df output of build_baseline()
#' @param z_thresh z-score magnitude that counts as anomalous
#' @param dev_thresh percentage deviation that counts as anomalous
#' @param min_abs_frac a deviation must also be at least this fraction of the
#'   building's own overall average consumption (floor 0.02 kWh) to count.
#'   This stops near-zero-baseline circuits (e.g. a "kitchen" meter that's
#'   usually ~0 kWh) from registering huge % swings on routine, tiny blips.
#' @return df with anomaly flags, z_score, deviation_pct, anomaly_type
detect_anomalies <- function(df, z_thresh = 2, dev_thresh = 30, min_abs_frac = 0.05) {

  out <- df %>%
    mutate(
      z_score        = (consumption_kwh - expected_mean) / expected_sd,
      deviation_pct  = 100 * (consumption_kwh - expected_mean) / pmax(expected_mean, 1e-6),
      iqr_low        = expected_q1 - 1.5 * expected_iqr,
      iqr_high       = expected_q3 + 1.5 * expected_iqr,
      min_abs_dev    = pmax(0.02, min_abs_frac * building_mean_kwh),
      abs_dev        = abs(consumption_kwh - expected_mean),
      meaningful     = abs_dev >= min_abs_dev,
      # % deviation is only a trustworthy signal when this hour's own
      # baseline isn't itself near zero relative to the building's scale --
      # otherwise any small blip reads as "+400%". z-score and IQR don't
      # have this problem since they're normalized by this hour's own sd,
      # so they stay fully in play even for bursty, near-zero circuits.
      reliable_pct   = expected_mean >= 0.15 * pmax(building_mean_kwh, 1e-6),
      iqr_flag       = (consumption_kwh < iqr_low | consumption_kwh > iqr_high) & meaningful,
      z_flag         = (abs(z_score) >= z_thresh) & meaningful,
      dev_flag       = (abs(deviation_pct) >= dev_thresh) & meaningful & reliable_pct,
      is_anomaly     = z_flag | iqr_flag | dev_flag,
      direction      = if_else(consumption_kwh >= expected_mean, "spike", "drop")
    )

  # repeated pattern: was this same (building, hour, day_type) anomalous on
  # >=2 of the previous 3 occurrences of that day-type?
  out <- out %>%
    arrange(building_id, hour, day_type, date) %>%
    group_by(building_id, hour, day_type) %>%
    mutate(
      prior_anomaly_rate = lag(zoo_roll_mean(as.numeric(is_anomaly), 3)),
      is_repeated        = !is.na(prior_anomaly_rate) & prior_anomaly_rate >= (2 / 3)
    ) %>%
    ungroup() %>%
    arrange(building_id, timestamp)

  out %>%
    mutate(
      anomaly_type = case_when(
        !is_anomaly                            ~ "none",
        is_night & direction == "spike"        ~ "night_spike",
        hour %in% 6:9 & direction == "spike"   ~ "morning_spike",
        is_peak_hour & direction == "spike"    ~ "peak_load_spike",
        direction == "drop"                    ~ "unexpected_drop",
        is_weekend                             ~ "weekend_anomaly",
        TRUE                                   ~ "general_spike"
      )
    ) %>%
    select(-min_abs_dev, -abs_dev, -meaningful, -reliable_pct)
}

# trailing rolling mean without the zoo package
zoo_roll_mean <- function(x, k) {
  n <- length(x)
  out <- rep(NA_real_, n)
  for (i in seq_len(n)) {
    lo <- max(1, i - k + 1)
    out[i] <- mean(x[lo:i], na.rm = TRUE)
  }
  out
}

# -----------------------------------------------------------------------------
# 5. ANOMALY SEVERITY SCORING
# -----------------------------------------------------------------------------
#' Score every row 0-100 and bucket into Normal / Low / Moderate / Critical.
#'
#'   0-20   Normal
#'   21-40  Low
#'   41-70  Moderate
#'   71-100 Critical
#'
#' Score = weighted blend of z-score magnitude + % deviation, with bonus
#' weight for anomalies that happen during normally low-demand (night) hours
#' or that are part of a repeated pattern -- because those are more likely to
#' reflect a real operational problem than random noise.
#'
#' @param df output of detect_anomalies()
#' @return df with anomaly_score (0-100) and severity_band
score_severity <- function(df) {
  df %>%
    mutate(
      z_component   = pmin(abs(z_score) / 4, 1) * 50,
      dev_component = pmin(abs(deviation_pct) / 100, 1) * 30,
      night_bonus   = if_else(is_night & is_anomaly, 10, 0),
      repeat_bonus  = if_else(is_repeated, 10, 0),
      anomaly_score = if_else(
        is_anomaly,
        pmin(100, round(z_component + dev_component + night_bonus + repeat_bonus)),
        pmin(20, round(z_component + dev_component))   # non-anomalies stay in "Normal"
      ),
      severity_band = case_when(
        anomaly_score <= 20 ~ "Normal",
        anomaly_score <= 40 ~ "Low",
        anomaly_score <= 70 ~ "Moderate",
        TRUE                 ~ "Critical"
      )
    ) %>%
    select(-z_component, -dev_component, -night_bonus, -repeat_bonus)
}

# -----------------------------------------------------------------------------
# 6. STATISTICAL EXPLANATION ("likely causes")
# -----------------------------------------------------------------------------
#' Guess a human-friendly "load type" phrase from the building/circuit name,
#' so the explanation text is specific ("kitchen appliance load") rather than
#' always saying "HVAC" for every building regardless of what it actually is.
load_type_phrase <- function(building_id) {
  b <- tolower(building_id)
  if (str_detect(b, "kitchen"))                       "kitchen appliance load (oven/dishwasher/microwave)"
  else if (str_detect(b, "laundry"))                  "laundry appliance load (washer/dryer)"
  else if (str_detect(b, "water heater|\\bac\\b|hvac|air.?con")) "water-heater / HVAC load"
  else                                                 "HVAC-related load"
}

#' Turn a single scored row into human-readable "likely causes" bullets,
#' the way the brief's example output does.
#'
#' @param row one row (as a list or 1-row tibble) from the scored dataset
#' @return character vector of bullet strings
explain_anomaly <- function(row) {
  reasons <- c()

  if (!isTRUE(row$is_anomaly)) {
    return("No significant deviation from the expected baseline for this hour.")
  }

  load_phrase <- load_type_phrase(row$building_id)

  if (row$hour %in% 6:9 && row$direction == "spike") {
    reasons <- c(reasons, sprintf("6:00-9:00 AM consumption spike (+%.0f%% vs expected)", row$deviation_pct))
  }
  if (row$is_weekend && row$consumption_kwh > row$expected_mean * 1.10) {
    reasons <- c(reasons, "Weekend baseline exceeded")
  }
  if (isTRUE(row$is_peak_hour) && row$direction == "spike") {
    reasons <- c(reasons, sprintf("Peak-load hours exceeded expected level -- %s increased", load_phrase))
  }
  if (row$is_night && row$direction == "spike") {
    reasons <- c(reasons, "Unusual night-time consumption (normally low-demand hours)")
  }
  if (row$direction == "drop") {
    reasons <- c(reasons, sprintf("Unexpected drop in consumption (%.0f%% below expected)", abs(row$deviation_pct)))
  }
  if (isTRUE(row$is_repeated)) {
    reasons <- c(reasons, "Repeated abnormal pattern at this hour across recent days")
  }
  if (abs(row$z_score) >= 2.5) {
    reasons <- c(reasons, sprintf("Consumption is %.1f\u03c3 %s expected level for this hour",
                                    abs(row$z_score),
                                    if (row$direction == "spike") "above" else "below"))
  }

  if (length(reasons) == 0) {
    reasons <- sprintf("Consumption deviates %.0f%% from the dynamic baseline for this hour/day-type", row$deviation_pct)
  }

  unique(reasons)
}

# -----------------------------------------------------------------------------
# CONVENIENCE: run the full pipeline in one call
# -----------------------------------------------------------------------------
run_pipeline <- function(raw_df, z_thresh = 2, dev_thresh = 30, min_abs_frac = 0.05) {
  raw_df %>%
    clean_energy_data() %>%
    build_baseline() %>%
    detect_anomalies(z_thresh = z_thresh, dev_thresh = dev_thresh, min_abs_frac = min_abs_frac) %>%
    score_severity()
}