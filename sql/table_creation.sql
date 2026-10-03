-- database creation 
create database hr_arrition_risk;

use hr_arrition_risk;

-- table creation
CREATE TABLE if not exists employee (
    employee_id INT PRIMARY KEY,
    age INT,
    business_travel VARCHAR(50),
    department VARCHAR(50),
    environment_satisfaction INT, 
    job_involvement INT,
    job_level INT,
    job_role VARCHAR(50),
    job_satisfaction INT,
    gender VARCHAR(10),
    marital_status VARCHAR(20),
    monthly_income INT,
    daily_rate INT,
    hourly_rate INT,
    monthly_rate INT,
    distance_from_home INT,
    education INT,
    education_field VARCHAR(50),
    performance_rating INT,
    relationship_satisfaction INT,
    stock_option_level INT,
    years_at_company INT,
    years_since_last_promotion INT,
    training_times_last_year INT,
    work_life_balance INT,
    num_companies_worked INT,
    years_with_curr_manager INT,
    years_in_current_role INT,
    total_working_years INT,
    percent_salary_hike INT,
    overtime VARCHAR(5),
    replacement_cost DECIMAL(10,2)
);

CREATE TABLE if not exists employee_prediction_history (
    prediction_id INT AUTO_INCREMENT PRIMARY KEY,
    employee_id INT NOT NULL,
    prediction_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    attrition_probability DECIMAL(5,4),
    risk_label VARCHAR(20),
    top_driver_1 VARCHAR(100),
    top_driver_1_impact DECIMAL(5,3),
    top_driver_2 VARCHAR(100),
    top_driver_2_impact DECIMAL(5,3),
    top_driver_3 VARCHAR(100),
    top_driver_3_impact DECIMAL(5,3),
    CONSTRAINT fk_employee
        FOREIGN KEY (employee_id) REFERENCES employee(employee_id)
);

-- creation of index on employee_id making searching easy
CREATE INDEX idx_employee_id ON employee_prediction_history(employee_id);

-- updating the replacement cost 
UPDATE employee e
SET e.replacement_cost = 
    CASE 
        WHEN e.job_level IN (1, 2) THEN (e.monthly_income * 12) * 1.0
        WHEN e.job_level IN (3, 4) THEN (e.monthly_income * 12) * 1.5
        WHEN e.job_level = 5 THEN (e.monthly_income * 12) * 2.0
    END;
   
-- creating latest_prediction view to show only the latest prediction for each employees 
CREATE VIEW latest_prediction AS
SELECT * FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY prediction_timestamp DESC) AS rn
    FROM employee_prediction_history
) t
WHERE t.rn = 1;

-- simple select query
SELECT e.*, p.attrition_probability, p.risk_label,
       p.top_driver_1, p.top_driver_1_impact,
       p.top_driver_2, p.top_driver_2_impact,
       p.top_driver_3, p.top_driver_3_impact
FROM employee e
JOIN latest_prediction p ON e.employee_id = p.employee_id;
