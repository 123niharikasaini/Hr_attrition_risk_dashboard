# HR Attrition Risk Dashboard

An end-to-end system that predicts which employees are at risk of resigning, explains **why** for each individual, and translates that risk into a **dollar cost** the business can act on.

> Most portfolio projects stop at "I built a model with X% accuracy." This project answers three separate business questions: **who** is at risk (prediction), **why** (per-employee explainability), and **what will it cost us** (dollar framing) - turning a model into a decision-support tool, not just a classifier.

---

## Architecture

```
Kaggle Dataset → Python (Model + SHAP) → MySQL (Storage) → Power BI (Dashboard)
```

| Layer | Tool | Responsibility |
|---|---|---|
| Modeling | Python (scikit-learn, SHAP) | Train model, generate predictions + per-employee explanations |
| Storage | MySQL | Normalized schema, prediction history, cost calculation |
| Visualization | Power BI | Interactive dashboard for HR |

---

## 1. Dataset

[IBM HR Analytics Employee Attrition](https://www.kaggle.com/datasets/pavansubhasht/ibm-hr-analytics-attrition-dataset) - 1,470 employees, 35 raw columns to 37 columns after encoding and multicollinearity removal.

**Class balance:** 83.9% No / 16.1% Yes (Attrition) - a severe imbalance that shapes nearly every downstream decision (metric choice, threshold, class weighting).

---

## 2. Modeling Pipeline (Python)

### Preprocessing
- **Encoding strategy chosen per column type**:
  - Ordinal mapping for `BusinessTravel` (has a real order: Non-Travel < Rarely < Frequently)
  - Binary mapping for `Gender`, `OverTime` (2 categories, one-hot would be redundant)
  - One-Hot Encoding (`drop_first=True`) for nominal columns with no natural order (`Department`, `JobRole`, `EducationField`, `MaritalStatus`)
- Encoder/mappings **fit only on `X_train`**, then applied (`.transform()`) to `X_test` and future data - prevents leakage and tests that `handle_unknown='ignore'` correctly handles unseen categories.
- **Multicollinearity** checked only among features (not feature-vs-target) and only on `X_train`. Dropped: `JobLevel`, `PerformanceRating`, `TotalWorkingYears`, `YearsWithCurrManager`, `YearsInCurrentRole`, `Department_Sales`.
- **Outlier check:** percentile-jump analysis (95th - 99th - max, not quartiles) on `MonthlyIncome`, `YearsAtCompany`, `YearsSinceLastPromotion` - no disproportionate jumps found, confirming these are genuine values, not data errors. Left untreated for the final model (Random Forest is threshold-based and outlier-robust).

### Class Imbalance
- `class_weight='balanced'` used instead of SMOTE - simpler, no synthetic data, appropriate for a dataset this size (only 237 minority examples).
- Combined with threshold tuning, achieved 83% recall without needing a more complex/riskier technique.

### Models
- **Logistic Regression** - interpretable baseline/benchmark (not the final model). Required `StandardScaler` (coefficient-based, scale-sensitive).
- **Random Forest** - final model. No scaling needed (threshold-based splits are scale-invariant). Tuned via `GridSearchCV` with `scoring='recall'` (not accuracy — accuracy rewards ignoring the minority class on imbalanced data).

### Threshold Tuning
- Default 0.5 replaced with **0.4**, chosen via explicit cost-asymmetry reasoning: a missed at-risk employee (False Negative) costs a full replacement (1.5–2x salary); a false alarm (False Positive) costs only HR's time. Recall prioritized accordingly.
- Binary classification only (High Risk / Low Risk) — no "Medium" tier implemented.

### Explainability — SHAP
- `shap.TreeExplainer(model)` - no background data needed/used (tree-based explainer).
- Per-employee **top-3 risk drivers** extracted using **absolute SHAP value** (not raw descending sort) — ensures strong protective factors (negative SHAP) aren't excluded in favor of weaker risk-increasing ones.
- **Known calibration caveat:** because `class_weight='balanced'` shifts the model's internal probability scale, raw probabilities are a **relative risk ranking**, not literal "X% chance of resigning."

---

## 3. Database Layer (MySQL)

### Schema design
Two tables, intentionally separated by **update frequency**, not just by subject:

- **`employee`** - static attributes (age, department, salary, job level, etc.) plus `replacement_cost` (job-level-based multiplier × annual salary). Changes rarely.
- **`employee_prediction_history`** - one row per model run per employee (surrogate `prediction_id` as primary key). Keeps a full history so HR can compare month-over-month and see whether an intervention reduced an employee's risk.

A `latest_prediction` **view** (using `ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY prediction_timestamp DESC)`) surfaces only the most recent prediction per employee - used by the dashboard, while the base table retains full history.

### Design decisions worth noting
- `employee_id` is taken from the dataset's **index**, not a fresh positional counter - verified with `.isin()` checks, since `train_test_split` can desynchronize a naive 0,1,2… index from the real identifier.
- `replacement_cost` lives in `employee`, not `employee_prediction_history` - it depends only on static attributes (salary, job level) and would otherwise be redundantly recalculated/repeated every prediction cycle.
- Inserts use `pandas.to_sql(..., if_exists='append')`; `prediction_id` is **never** passed from Python - left to `AUTO_INCREMENT` to avoid ID collisions across runs.

---

## 4. Monthly Prediction Pipeline (Python)

A **separate notebook** from training — mirrors a real training/inference pipeline split:

1. Load saved artifacts: `model.pkl`, `mappings.pkl`, `encoder.pkl`, `feature_cols.pkl`
2. Pull current employee data from MySQL (not a manually maintained CSV)
3. Apply the **exact same transformation pipeline** used during training (same mappings, same fitted encoder, same column order)
4. Predict on **all employees** (not just the original test split — production inference needs every current employee, train/test is a modeling-evaluation concept only)
5. Extract top-3 SHAP drivers per employee
6. Append the batch to `employee_prediction_history` in MySQL

**Known limitation:** predictions for employees who were in the original training set may be mildly optimistic, since the model has already seen them.

---

## 5. Dashboard (Power BI)

Connected via **Import mode** (MySQL Connector/NET), department-level slicer with cross-filtering (`Both` direction, `One-to-One` relationship between `employee` and `latest_prediction`).

**Includes:**
- KPI cards: Total Employees, Overall Attrition Risk Rate, High Risk Count, Total Replacement Cost Exposure
- Attrition Risk by Department / Job Role / Job Level (stacked bar)
- **Top Factors Driving Attrition Risk** and **Top Factors Reducing Attrition Risk** - built from a long-format transformation (`Unpivot`) of the three wide `top_driver_*` columns, ranked by **employee count** (not average impact), since HR acts on factors affecting the most people, not the single strongest outlier case
- Employee-level detail table (High Risk employees, their drivers, department, replacement cost)

---

## Known Limitations / Future Enhancements

- [ ] Empirically test whether outlier-capping changes Logistic Regression's recall (currently assumed negligible, not tested)
- [ ] Group one-hot encoded sub-columns (e.g. `JobRole_Sales Executive`, `JobRole_Research Scientist`) back to their parent feature (`JobRole`) for cleaner, business-readable SHAP driver labels
- [ ] Month-over-month trend visual - schema supports it (full prediction history is retained), but not enough historical runs exist yet to populate it meaningfully
- [ ] Race-condition-safe employee inserts (`INSERT IGNORE` / `ON DUPLICATE KEY UPDATE`) if this pipeline is ever automated/scheduled, replacing the current single-run Python-side duplicate check
- [ ] Formally verify feature-interaction hypotheses (e.g. `DistanceFromHome` × `MonthlyIncome`) via SHAP dependence plots
- [ ] Probability calibration, to recover real-world percentage interpretation currently lost to `class_weight='balanced'`
- [ ] Row-Level Security in Power BI (managers see only their own team)

---

## Key Design Principles Applied Throughout

- **No test-set leakage**: every `fit()` (scaler, encoder) happens on `X_train` only; `X_test` and future data only ever use `.transform()`.
- **Simple-first escalation**: `class_weight='balanced'` before SMOTE, threshold-tuning before added model complexity - each justified by testing the simpler option first.
- **Business framing over raw metrics**: the 0.4 threshold is justified by an explicit cost-asymmetry argument (missed employee ≫ false alarm), not by which number looked best on a metric.
- **Verify, don't assume**: every surprising result (identical grid-search outputs, boxplot "steep" jumps, a `False` column-matching check) was checked against source data before being accepted.
