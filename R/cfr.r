# Packages ----------------------------------------------------------------
library(here)
library(dplyr)
library(tidyr)
library(vroom)
library(lubridate)
library(brms)
library(parallel)

# set number of parallel cores
no_cores <- detectCores()

# Data --------------------------------------------------------------------
# get raw cases by data of infection from epiforecasts.io 
case_infs <- vroom(paste0("https://raw.githubusercontent.com/epiforecasts/covid-rt-estimates/",
                          "master/subnational/united-kingdom-local/cases/summary/cases_by_infection.csv")) %>% 
  mutate(data = "cases")
# get raw deaths by data of infection from epiforecasts.io 
death_infs <- vroom(paste0("https://raw.githubusercontent.com/epiforecasts/covid-rt-estimates/",
                           "master/subnational/united-kingdom-local/deaths/summary/cases_by_infection.csv")) %>% 
  mutate(data = "deaths")

# link datasets and pivot wider
infections <- case_infs %>% 
  bind_rows(death_infs) %>% 
  filter(type == "estimate") %>% 
  select(utla_name = region, date, data, value = median) %>% 
  pivot_wider(names_from = "data") %>% 
  group_by(utla_name) %>% 
  complete(date = seq(min(date), max(date), by = "day")) %>% 
  mutate(cases = replace_na(cases, 0)) %>% 
  drop_na(deaths)

# Define covariates -------------------------------------------------------
# get variant proportion
sgene_by_utla <- readRDS(here("data", "sgene_by_utla.rds")) %>% 
  drop_na(prop_sgtf) %>% 
  filter(week_infection > "2020-10-01")

# make infections weekly summary
weekly_infections <- infections %>% 
  mutate(week_infection = floor_date(date, "week", week_start = wday(max(sgene_by_utla$week_infection)) - 1)) %>% 
  group_by(utla_name, week_infection) %>%
  summarise(cases = sum(cases), deaths = sum(deaths), n = n(), .groups = "drop") %>%
  filter(n == 7) %>%
  select(-n)

# link with variant proportion
deaths_with_cov <- weekly_infections %>% 
  inner_join(sgene_by_utla, by = c("week_infection", "utla_name")) %>% 
  select(utla = utla_name, week_infection, region = nhser_name, 
         deaths, cases, prop_sgtf, samples)

# make normalised predictors
deaths_with_cov <- deaths_with_cov %>% 
  mutate(normalised_cases = (cases - mean(cases)) / sd(cases),
         time = as.numeric(week_infection),
         time = time - min(time),
         time = (time - mean(time)) / sd(time))

# Define model ------------------------------------------------------------
# D = c^{+}(1-f)C + c^{-}fC
# where c is the CFR, f is the fraction of cases that are sgtf, C is the number
# of cases by date of infection, and D is the number of deaths by date of infection
# effect of the variant on the CFR is assumed to be:
# c^{-} = \alpha c^{+} or c^{-} = \alpha + c^{+}
# leading to:
# D = (1 - (\alpha - 1)f)c^{+}C or D = (c^{+} + \alpha f)C 
# define custom negative binomial family including variant factor and cases
variant_nb <- function(additive = FALSE) {
  custom_family(
    "variant_nb", dpars = c("mu", "phi", "alpha"),
    links = c("logit", "log", "identity"),
    lb = c(0, 0, ifelse(!additive, 0, -1)),
    type = "int",
    vars = c("f[n]", "cases[n]", "effect[1]")
  )
}

# define stan code to scale cfr by cases and variant fraction
make_stanvars <- function(data, additive = FALSE) {
  stan_funs <- "
real variant_nb_lpmf(int y, real mu, real phi, real alpha,
                     real f, int cases, int effect) {
    real scaled_cases;
    if (effect) {
      scaled_cases = (mu + alpha * f) * cases;
    }else {
      scaled_cases = (1 + (alpha - 1) * f) * mu * cases;
    }
    return  neg_binomial_2_lpmf(y | scaled_cases, phi);
                            }
real variant_nb_rng(int y, real mu, real phi, real alpha,
                    real f, int cases, int effect) {
    real scaled_cases;
    if (effect) {
      scaled_cases = (mu + alpha * f) * cases;
    }else {
      scaled_cases = (1 + (alpha - 1) * f) * mu * cases;
    }
    return  neg_binomial_2_rng(scaled_cases, phi);
                            }
"
  stanvars <- c(stanvar(block = "functions", scode = stan_funs),
                stanvar(block = "data",
                        scode = "  real f[N];",
                        x = data$prop_sgtf,
                        name = "f"),
                stanvar(block = "data",
                        scode = "  int cases[N];",
                        x = data$cases,
                        name = "cases"),
                stanvar(block = "data",
                        scode = "  int effect[1];",
                        x = array(as.numeric(additive)),
                        name = "effect")
  )
  return(stanvars)
}

# define model function
nb_model <- function(form, iter = 1500, data = deaths_with_cov,
                     additive = FALSE, ...) {
  # define priors
  if (additive) {
    priors <- c(prior(normal(0, 1), class = alpha))
  }else{
    priors <- c(prior(lognormal(0, 1), class = alpha))
  }
  message("Fitting: ", as.character(form))
  brm(formula = form,
      family = variant_nb(additive = additive),
      prior = priors,
      data,
      stanvars = make_stanvars(data, additive = additive),
      control = list(adapt_delta = 0.95),
      warmup = 500, iter = iter, ...)
}
# Fit models --------------------------------------------------------------
models <- list()
# define models to fit
models[["intercept"]] <- as.formula(deaths ~ 1)
models[["cases"]] <- as.formula(deaths ~ s(normalised_cases, k = 5))
models[["region"]] <- as.formula(deaths ~ region)
models[["time"]] <- as.formula(deaths ~ s(time, k = 9))
models[["utla"]] <- as.formula(deaths ~ (1 | utla))
models[["all"]] <- as.formula(deaths ~ s(normalised_cases, k = 5) + s(time, k = 5) + region + (1 | utla))
models[["all_with_residuals"]] <- as.formula(deaths ~ s(normalised_cases, k = 5) + s(time, k = 5) + region + (1 | utla))
models[["all_with_regional_residuals"]] <- as.formula(deaths ~ s(normalised_cases, k = 5) + s(time, k = 5, by = region) + (1 | utla))

# core usage
if (no_cores <= 4) { 
  options(mc.cores = no_cores)
  mc_cores <- 1
}else{
  options(mc.cores = ceiling(no_cores / length(models)))
  mc_cores <- min(length(models), no_cores)
}
# fit models
fits <- list()
fits[["multiplicative"]] <- mclapply(models, nb_model, mc.cores = mc_cores)
fits[["additive"]] <- mclapply(models, nb_model, mc.cores = mc_cores, additive = TRUE)

# Variant effect ----------------------------------------------------------
extract_variant_effect <- function(x, additive = FALSE) {  
  samples <- posterior_samples(x, "alpha")
  q <- samples[, "alpha"]
  q <- ifelse(!additive, q - 1, q)
  q <- quantile(q, c(0.025, 0.5, 0.975))
  q <- round(q, 2)
  return(q)
}
variant_effect <- list()
variant_effect[["multiplicative"]] <- lapply(fits[["multiplicative"]], extract_variant_effect) 
variant_effect[["additive"]] <- lapply(fits[["additive"]], extract_variant_effect, additive = TRUE) 

# Compare models ----------------------------------------------------------
# requires custom log_lik functions to be implemented for variant_nb family