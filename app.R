# =============================================================================
# PowerPulse -- Electricity Consumption Anomaly Intelligence
# =============================================================================
# A Shiny dashboard that goes beyond "predict electricity demand" and instead
# answers: "why is today's consumption abnormal?" -- at THREE resolutions:
#   - Hourly  -> operational spikes/drops (dynamic per-hour baseline)
#   - Daily   -> "this Tuesday was 2.3sigma above normal Tuesdays"
#   - Weekly  -> trend-level drift vs. this building's own weekly history
#
# HOW TO RUN
# -----------------------------------------------------------------------------
#   1. Open R or RStudio in this project folder (powerpulse/).
#   2. install.packages(c("shiny","bslib","dplyr","tidyr","lubridate",
#                          "purrr","stringr","ggplot2","plotly","DT","readr"))
#   3. If data/energy_data.csv does not exist yet, generate a sample dataset:
#        source("R/generate_data.R")
#      (Or drop in your own CSV with columns: building_id, timestamp,
#       consumption_kwh -- see R/generate_data.R header for the exact format.)
#   4. Run the app:
#        shiny::runApp()
#      or click "Run App" in RStudio.
# =============================================================================

library(shiny)
library(bslib)
library(dplyr)
library(tidyr)
library(lubridate)
library(purrr)
library(stringr)
library(ggplot2)
library(plotly)
library(DT)
library(readr)

source("R/pipeline.R")

DATA_PATH <- "data/energy_data.csv"

if (!file.exists(DATA_PATH)) {
  message("No data/energy_data.csv found -- generating a sample dataset...")
  source("R/generate_data.R")
}

raw_data <- read_csv(DATA_PATH, show_col_types = FALSE)

# Clean once, reuse everywhere (hourly pipeline, profiling, daily/weekly).
cleaned_data <- clean_energy_data(raw_data)

# Run the whole HOURLY analytics pipeline ONCE at app startup. It's cheap
# enough (thousands of rows) to keep entirely in memory and filter reactively.
scored_data <- run_pipeline(raw_data)
profiles    <- profile_consumption(cleaned_data)

# Daily/weekly detectors are re-run reactively (see live_daily/live_weekly)
# so the same sensitivity sliders drive all three resolutions consistently.

severity_colors <- c(
  "Normal"   = "#4CAF50",
  "Low"      = "#8BC34A",
  "Moderate" = "#FF9800",
  "Critical" = "#E53935"
)

# =============================================================================
# UI
# =============================================================================
ui <- page_sidebar(
  fillable = FALSE,
  title = tagList(
    span(style = "font-weight:800; letter-spacing:0.5px;", "\u26A1 POWERPULSE"),
    span(style = "font-weight:400; font-size:0.75em; color:#888; margin-left:8px;",
         "Energy Anomaly Intelligence")
  ),
  theme = bs_theme(
    version = 5,
    bg = "#0f1115", fg = "#e8e8ea",
    primary = "#4C8BF5",
    base_font = font_google("Inter"),
    "border-radius" = "0.6rem"
  ),

  sidebar = sidebar(
    width = 280,
    h5("Controls"),
    selectInput("building", "Building", choices = sort(unique(scored_data$building_id))),
    dateInput("focus_date", "Date to inspect",
              value = max(scored_data$date),
              min   = min(scored_data$date),
              max   = max(scored_data$date)),
    sliderInput("z_thresh", "Z-score sensitivity", min = 1, max = 3.5, value = 2, step = 0.1),
    sliderInput("dev_thresh", "% deviation sensitivity", min = 10, max = 60, value = 30, step = 5),
    hr(),
    helpText("Lower sensitivity values flag more anomalies. Defaults match the ",
             "statistical thresholds used in the write-up (z \u2265 2, deviation \u2265 30%). ",
             "These sliders drive all three resolutions below: hourly, daily, and weekly."),
    hr(),
    h6("About the baselines"),
    p(style = "font-size:0.8em; color:#999;",
      "Hourly expected consumption is computed per building, per hour-of-day, and per ",
      "day-type (weekday vs weekend). Daily expected totals are computed per building, ",
      "day-type, and season (a summer Tuesday is judged against other summer Tuesdays). ",
      "Weekly expected totals are each building's own leave-one-week-out history. ",
      "None of these use a single flat threshold.")
  ),

  # ---- Top row: KPI value boxes --------------------------------------------
  layout_columns(
    fill = FALSE,
    value_box(
      title = "Today's Consumption",
      value = textOutput("kpi_today", inline = TRUE),
      showcase = bsicons::bs_icon("lightning-charge-fill"),
      theme = "primary"
    ),
    value_box(
      title = "Hourly Anomalies Today",
      value = textOutput("kpi_anomalies", inline = TRUE),
      showcase = bsicons::bs_icon("exclamation-triangle-fill"),
      theme = "danger"
    ),
    value_box(
      title = "Peak Hourly Load",
      value = textOutput("kpi_peak", inline = TRUE),
      showcase = bsicons::bs_icon("graph-up-arrow"),
      theme = "warning"
    ),
    value_box(
      title = "vs. Normal Daily Avg",
      value = textOutput("kpi_vs_normal", inline = TRUE),
      showcase = bsicons::bs_icon("arrow-left-right"),
      theme = "secondary"
    )
  ),

  # ---- Second row: multi-resolution KPI value boxes -------------------------
  layout_columns(
    fill = FALSE,
    value_box(
      title = "Anomalous Days (all-time)",
      value = textOutput("kpi_daily_anomalies", inline = TRUE),
      showcase = bsicons::bs_icon("calendar-week-fill"),
      theme = "danger"
    ),
    value_box(
      title = "Anomalous Weeks (all-time)",
      value = textOutput("kpi_weekly_anomalies", inline = TRUE),
      showcase = bsicons::bs_icon("calendar3-range-fill"),
      theme = "warning"
    )
  ),

  # ---- Middle: actual vs expected chart -------------------------------------
  card(
    full_screen = TRUE,
    card_header("Actual vs Expected Consumption (Hourly)"),
    plotlyOutput("main_chart", height = "380px")
  ),

  layout_columns(
    col_widths = c(7, 5),

    # ---- Detected anomalies table -----------------------------------------
    card(
      card_header("Detected Anomalies (Hourly)"),
      DTOutput("anomaly_table")
    ),

    # ---- Detail panel for the selected anomaly -----------------------------
    card(
      card_header("Anomaly Detail"),
      uiOutput("detail_panel")
    )
  ),

  # ---- NEW: Daily & Weekly anomaly detection --------------------------------
  card(
    full_screen = TRUE,
    card_header("Trend-Level Anomaly Detection (Daily & Weekly)"),
    tabsetPanel(
      id = "trend_tabs",
      tabPanel(
        "Daily",
        br(),
        p(style = "font-size:0.85em; color:#999;",
          "Each day's total kWh is compared against this building's own history for that ",
          "day-type and season (leave-one-day-out), e.g. \"this Tuesday's total was 2.3\u03c3 ",
          "above normal summer Tuesdays.\" Only flagged days are shown."),
        DTOutput("daily_table")
      ),
      tabPanel(
        "Weekly",
        br(),
        p(style = "font-size:0.85em; color:#999;",
          "Each ISO week's total kWh is compared against this building's own leave-one-week-out ",
          "history, surfacing slower trend-level drift that hourly/daily checks can miss. ",
          "Only flagged weeks are shown."),
        DTOutput("weekly_table")
      )
    )
  ),

  # ---- Bottom: profiling section --------------------------------------------
  layout_columns(
    col_widths = c(4, 4, 4),
    card(
      card_header("Weekday vs Weekend (avg kWh/hr)"),
      plotOutput("weekday_weekend_plot", height = "260px")
    ),
    card(
      card_header("Weekly Pattern (avg kWh/hr by day)"),
      plotOutput("weekly_plot", height = "260px")
    ),
    card(
      card_header("Seasonal Pattern (avg kWh/hr)"),
      plotOutput("seasonal_plot", height = "260px")
    )
  )
)

# =============================================================================
# SERVER
# =============================================================================
server <- function(input, output, session) {

  # ---- HOURLY: re-run detection with user-adjustable sensitivity sliders ---
  # Reuses the already-cleaned/baselined data so this stays fast.
  live_scored <- reactive({
    scored_data %>%
      select(-z_flag, -iqr_flag, -dev_flag, -is_anomaly, -anomaly_type,
             -anomaly_score, -severity_band, -is_repeated, -prior_anomaly_rate) %>%
      detect_anomalies(z_thresh = input$z_thresh, dev_thresh = input$dev_thresh) %>%
      score_severity()
  })

  # ---- DAILY & WEEKLY: same sliders drive these two resolutions too --------
  live_daily <- reactive({
    detect_daily_anomalies(cleaned_data, z_thresh = input$z_thresh, dev_thresh = input$dev_thresh)
  })

  live_weekly <- reactive({
    detect_weekly_anomalies(cleaned_data, z_thresh = input$z_thresh, dev_thresh = input$dev_thresh)
  })

  day_data <- reactive({
    req(input$building, input$focus_date)
    live_scored() %>%
      filter(building_id == input$building, date == input$focus_date) %>%
      arrange(hour)
  })

  building_history <- reactive({
    req(input$building)
    live_scored() %>% filter(building_id == input$building)
  })

  building_daily <- reactive({
    req(input$building)
    live_daily() %>%
      filter(building_id == input$building) %>%
      arrange(desc(date))
  })

  building_weekly <- reactive({
    req(input$building)
    live_weekly() %>%
      filter(building_id == input$building) %>%
      arrange(desc(week_start))
  })

  # baseline "normal" daily total for this building (median of daily totals)
  normal_daily_total <- reactive({
    building_history() %>%
      group_by(date) %>%
      summarise(total = sum(consumption_kwh), .groups = "drop") %>%
      summarise(med = median(total)) %>%
      pull(med)
  })

  # ---- KPI outputs -----------------------------------------------------------
  output$kpi_today <- renderText({
    d <- day_data()
    sprintf("%.0f kWh", sum(d$consumption_kwh))
  })

  output$kpi_anomalies <- renderText({
    d <- day_data()
    as.character(sum(d$is_anomaly))
  })

  output$kpi_peak <- renderText({
    d <- day_data()
    sprintf("%.0f kW", max(d$consumption_kwh, na.rm = TRUE))
  })

  output$kpi_vs_normal <- renderText({
    d <- day_data()
    today_total <- sum(d$consumption_kwh)
    normal <- normal_daily_total()
    pct <- 100 * (today_total - normal) / normal
    sprintf("%+.1f%%", pct)
  })

  output$kpi_daily_anomalies <- renderText({
    as.character(sum(building_daily()$is_anomaly))
  })

  output$kpi_weekly_anomalies <- renderText({
    as.character(sum(building_weekly()$is_anomaly))
  })

  # ---- Main chart: actual vs expected, anomalies highlighted -----------------
  output$main_chart <- renderPlotly({
    d <- day_data()
    validate(need(nrow(d) > 0, "No data for this building/date combination."))

    p <- plot_ly(d, x = ~hour) %>%
      add_ribbons(
        ymin = ~pmax(0, expected_mean - expected_sd),
        ymax = ~expected_mean + expected_sd,
        name = "Expected range (\u00B11\u03C3)",
        fillcolor = "rgba(76,139,245,0.15)",
        line = list(width = 0),
        hoverinfo = "skip"
      ) %>%
      add_lines(y = ~expected_mean, name = "Expected", line = list(color = "#4C8BF5", dash = "dash")) %>%
      add_trace(
        y = ~consumption_kwh, name = "Actual", type = "scatter", mode = "lines+markers",
        line = list(color = "#e8e8ea"),
        marker = list(
          color = ~severity_colors[severity_band],
          size  = ~ifelse(is_anomaly, 11, 5),
          line  = list(color = "#0f1115", width = 1)
        ),
        text = ~sprintf("Hour %02d:00<br>Actual: %.1f kWh<br>Expected: %.1f kWh<br>Deviation: %+.1f%%<br>Severity: %s",
                         hour, consumption_kwh, expected_mean, deviation_pct, severity_band),
        hoverinfo = "text"
      ) %>%
      layout(
        paper_bgcolor = "rgba(0,0,0,0)",
        plot_bgcolor  = "rgba(0,0,0,0)",
        font = list(color = "#e8e8ea"),
        xaxis = list(title = "Hour of day", dtick = 2, gridcolor = "#2a2d34"),
        yaxis = list(title = "kWh", gridcolor = "#2a2d34"),
        legend = list(orientation = "h", y = -0.2)
      )
    p
  })

  # ---- Anomaly table (hourly) -----------------------------------------------
  type_icon <- c(
    night_spike      = "\U0001F319 Night Spike",
    morning_spike    = "\U0001F525 Morning Spike",
    peak_load_spike  = "\u26A1 Peak Load Spike",
    unexpected_drop  = "\U0001F4C9 Unexpected Drop",
    weekend_anomaly  = "\U0001F4C5 Weekend Anomaly",
    general_spike    = "\U0001F525 General Spike"
  )

  anomalies_today <- reactive({
    day_data() %>%
      filter(is_anomaly) %>%
      arrange(desc(anomaly_score)) %>%
      transmute(
        Time      = sprintf("%02d:00", hour),
        Deviation = sprintf("%+.0f%%", deviation_pct),
        Type      = paste0(
          unname(type_icon[anomaly_type]),
          if_else(is_repeated, " \U0001F501", "")
        ),
        Score     = anomaly_score,
        Severity  = severity_band,
        hour_key  = hour
      )
  })

  output$anomaly_table <- renderDT({
    d <- anomalies_today()
    validate(need(nrow(d) > 0, "No anomalies detected for this day \u2014 consumption stayed within the expected baseline."))
    datatable(
      d %>% select(-hour_key),
      selection = "single",
      rownames = FALSE,
      options = list(dom = "t", pageLength = 24, ordering = FALSE),
      class = "compact stripe"
    ) %>%
      formatStyle(
        "Severity",
        target = "row",
        backgroundColor = styleEqual(names(severity_colors), paste0(unname(severity_colors), "22"))
      )
  })

  # ---- Detail panel: click a row -> explanation ----------------------------
  output$detail_panel <- renderUI({
    sel <- input$anomaly_table_rows_selected
    d <- anomalies_today()

    if (is.null(sel) || nrow(d) == 0) {
      return(p(style = "color:#888;",
               "Click a row in the anomaly table to see its detailed statistical explanation."))
    }

    chosen_hour <- d$hour_key[sel]
    row <- day_data() %>% filter(hour == chosen_hour) %>% as.list()
    reasons <- explain_anomaly(row)
    color <- severity_colors[[row$severity_band]]

    tagList(
      div(
        style = sprintf("border-left:4px solid %s; padding-left:10px; margin-bottom:10px;", color),
        h5(sprintf("%s \u2014 %02d:00", input$building, row$hour)),
        span(
          style = sprintf(
            "background:%s; color:white; padding:2px 10px; border-radius:12px; font-weight:600; font-size:0.85em;",
            color
          ),
          sprintf("%s \u00B7 Score %d/100", toupper(row$severity_band), row$anomaly_score)
        )
      ),
      tags$table(
        style = "width:100%; font-size:0.9em; margin-bottom:10px;",
        tags$tr(tags$td("Actual"),   tags$td(style="text-align:right;", sprintf("%.1f kWh", row$consumption_kwh))),
        tags$tr(tags$td("Expected"), tags$td(style="text-align:right;", sprintf("%.1f kWh", row$expected_mean))),
        tags$tr(tags$td("Deviation"),tags$td(style="text-align:right;", sprintf("%+.1f%%", row$deviation_pct))),
        tags$tr(tags$td("Z-score"),  tags$td(style="text-align:right;", sprintf("%.2f\u03C3", row$z_score)))
      ),
      h6("Likely causes"),
      tags$ul(lapply(reasons, tags$li))
    )
  })

  # ---- NEW: Daily anomaly table ---------------------------------------------
  daily_table_data <- reactive({
    d <- building_daily() %>% filter(is_anomaly)
    validate(need(nrow(d) > 0,
                  "No daily-level anomalies detected for this building at the current sensitivity."))

    explanations <- purrr::pmap_chr(d, function(...) explain_daily_anomaly(list(...)))

    d %>%
      mutate(Explanation = explanations) %>%
      arrange(desc(anomaly_score), desc(date)) %>%
      transmute(
        Date        = format(date, "%Y-%m-%d"),
        Day         = as.character(wday_label),
        Season      = season,
        `Total kWh` = sprintf("%.0f", total_kwh),
        Deviation   = sprintf("%+.0f%%", deviation_pct),
        `Z-score`   = sprintf("%.2f\u03C3", z_score),
        Score       = anomaly_score,
        Severity    = severity_band,
        Explanation = Explanation
      )
  })

  output$daily_table <- renderDT({
    d <- daily_table_data()
    datatable(
      d,
      rownames = FALSE,
      options = list(pageLength = 8, scrollX = TRUE),
      class = "compact stripe"
    ) %>%
      formatStyle(
        "Severity",
        target = "row",
        backgroundColor = styleEqual(names(severity_colors), paste0(unname(severity_colors), "22"))
      )
  })

  # ---- NEW: Weekly anomaly table ---------------------------------------------
  weekly_table_data <- reactive({
    d <- building_weekly() %>% filter(is_anomaly)
    validate(need(nrow(d) > 0,
                  "No weekly-level anomalies detected for this building at the current sensitivity."))

    explanations <- purrr::pmap_chr(d, function(...) explain_weekly_anomaly(list(...)))

    d %>%
      mutate(Explanation = explanations) %>%
      arrange(desc(anomaly_score), desc(week_start)) %>%
      transmute(
        `Week of`   = format(week_start, "%Y-%m-%d"),
        `Total kWh` = sprintf("%.0f", total_kwh),
        Deviation   = sprintf("%+.0f%%", deviation_pct),
        `Z-score`   = sprintf("%.2f\u03C3", z_score),
        Score       = anomaly_score,
        Severity    = severity_band,
        Explanation = Explanation
      )
  })

  output$weekly_table <- renderDT({
    d <- weekly_table_data()
    datatable(
      d,
      rownames = FALSE,
      options = list(pageLength = 8, scrollX = TRUE),
      class = "compact stripe"
    ) %>%
      formatStyle(
        "Severity",
        target = "row",
        backgroundColor = styleEqual(names(severity_colors), paste0(unname(severity_colors), "22"))
      )
  })

  # ---- Profiling plots -------------------------------------------------------
  output$weekday_weekend_plot <- renderPlot({
    d <- profiles$weekday_vs_weekend %>% filter(building_id == input$building)
    ggplot(d, aes(x = day_type, y = avg_kwh, fill = day_type)) +
      geom_col(width = 0.55) +
      scale_fill_manual(values = c(weekday = "#4C8BF5", weekend = "#8BC34A")) +
      labs(x = NULL, y = "Avg kWh") +
      theme_minimal(base_size = 13) +
      theme(legend.position = "none",
            panel.grid.minor = element_blank())
  }, bg = "transparent")

  output$weekly_plot <- renderPlot({
    d <- profiles$weekly %>% filter(building_id == input$building)
    ggplot(d, aes(x = wday_label, y = avg_kwh, group = 1)) +
      geom_line(color = "#4C8BF5", linewidth = 1) +
      geom_point(color = "#4C8BF5", size = 2.5) +
      labs(x = NULL, y = "Avg kWh") +
      theme_minimal(base_size = 13) +
      theme(panel.grid.minor = element_blank())
  }, bg = "transparent")

  output$seasonal_plot <- renderPlot({
    d <- profiles$seasonal %>%
      filter(building_id == input$building) %>%
      mutate(season = factor(season, levels = c("Winter", "Spring", "Summer", "Autumn")))
    validate(need(nrow(d) > 0, "Not enough data across seasons yet for this building."))
    ggplot(d, aes(x = season, y = avg_kwh, fill = season)) +
      geom_col(width = 0.6) +
      scale_fill_manual(values = c(
        Winter = "#4C8BF5", Spring = "#8BC34A", Summer = "#FF9800", Autumn = "#B08968"
      )) +
      labs(x = NULL, y = "Avg kWh") +
      theme_minimal(base_size = 13) +
      theme(legend.position = "none", panel.grid.minor = element_blank())
  }, bg = "transparent")
}

shinyApp(ui, server)