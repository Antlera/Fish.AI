"""Generate the evaluation dataset and its ground truth.

Deterministic (fixed seed). Writes employees.xlsx (two sheets) and sales.csv into the
given directory and returns a dict of expected answers computed with pandas, so the
grader never relies on a human-typed number.
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats


def make(workspace: str | Path) -> dict:
    ws = Path(workspace)
    ws.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(20260902)

    n = 180
    depts = rng.choice(["研发", "销售", "市场", "财务", "人事"], size=n, p=[0.35, 0.3, 0.15, 0.1, 0.1])
    base = {"研发": 15000, "销售": 11000, "市场": 12000, "财务": 13000, "人事": 10000}
    salary = np.array([base[d] for d in depts]) + rng.normal(0, 2200, n)
    salary = np.round(salary / 100) * 100
    gender = rng.choice(["男", "女"], size=n, p=[0.55, 0.45])
    # a real, detectable gender gap so the t-test has a definite answer
    salary = salary + np.where(gender == "男", 900, 0)
    age = np.clip(np.round(22 + (salary - 10000) / 900 + rng.normal(0, 4, n)), 21, 60)
    hire = pd.Timestamp("2015-01-01") + pd.to_timedelta(rng.integers(0, 3600, n), unit="D")
    emp = pd.DataFrame({
        "id": np.arange(1001, 1001 + n),
        "name": [f"员工{i:03d}" for i in range(1, n + 1)],
        "dept": depts,
        "gender": gender,
        "age": age.astype(int),
        "salary": salary,
        "hire_date": hire.normalize(),
    })
    # three deliberate outliers and some missing values
    emp.loc[[7, 61, 133], "salary"] = [58000.0, 61500.0, 1200.0]
    emp.loc[rng.choice(n, 6, replace=False), "age"] = np.nan
    emp.loc[rng.choice(n, 4, replace=False), "dept"] = None

    bonus = pd.DataFrame({
        "id": rng.choice(emp["id"], size=150, replace=False),
    })
    bonus["bonus"] = np.round(rng.uniform(1000, 9000, len(bonus)) / 100) * 100
    bonus = bonus.sort_values("id").reset_index(drop=True)

    with pd.ExcelWriter(ws / "employees.xlsx") as xw:
        emp.to_excel(xw, sheet_name="Employees", index=False)
        bonus.to_excel(xw, sheet_name="Bonus", index=False)

    days = pd.date_range("2025-01-01", "2025-12-31", freq="D")
    sales = pd.DataFrame({
        "date": rng.choice(days, size=900),
        "region": rng.choice(["华东", "华北", "华南"], size=900),
        "amount": np.round(rng.gamma(2.0, 800, 900), 2),
    }).sort_values("date").reset_index(drop=True)
    sales.to_csv(ws / "sales.csv", index=False, encoding="utf-8")

    # ---- ground truth, computed the same way a careful analyst would ----
    s = emp["salary"]
    q1, q3 = s.quantile(0.25), s.quantile(0.75)
    iqr = q3 - q1
    outliers = s[(s < q1 - 1.5 * iqr) | (s > q3 + 1.5 * iqr)]
    dept_mean = emp.groupby("dept")["salary"].mean()
    merged = emp.merge(bonus, on="id", how="left")
    monthly = sales.groupby(sales["date"].dt.month)["amount"].sum()
    corr = emp[["age", "salary"]].dropna().corr().iloc[0, 1]
    male, female = s[emp["gender"] == "男"], s[emp["gender"] == "女"]
    welch = stats.ttest_ind(male, female, equal_var=False)
    student = stats.ttest_ind(male, female, equal_var=True)
    mw = stats.mannwhitneyu(male, female)
    xs = [4, 8, 15, 16, 23, 42]

    return {
        "employees_rows": int(len(emp)), "employees_cols": int(emp.shape[1]),
        "bonus_rows": int(len(bonus)), "bonus_cols": int(bonus.shape[1]),
        "salary_mean": float(s.mean()), "salary_median": float(s.median()), "salary_sd": float(s.std(ddof=1)),
        "top_dept": str(dept_mean.idxmax()), "top_dept_mean": float(dept_mean.max()),
        "outlier_count": int(len(outliers)),
        "missing": {c: int(v) for c, v in emp.isna().sum().items() if v},
        "top_month": int(monthly.idxmax()), "top_month_total": float(monthly.max()),
        "corr_age_salary": float(corr),
        "merged_rows": int(len(merged)), "merged_bonus_missing": int(merged["bonus"].isna().sum()),
        "male_mean": float(male.mean()), "female_mean": float(female.mean()),
        "ttest_p_welch": float(welch.pvalue), "ttest_p_student": float(student.pvalue), "mw_p": float(mw.pvalue),
        "small_sd": float(np.std(xs, ddof=1)), "small_mean": float(np.mean(xs)),
    }


if __name__ == "__main__":
    import json
    truth = make(sys.argv[1] if len(sys.argv) > 1 else "eval/.data")
    print(json.dumps(truth, ensure_ascii=False, indent=1))
