CREATE TABLE `__PROJECT_ID__.__BQ_DVT_DATASET__.results`
(
  run_id STRING OPTIONS(description="Unique validation run id"),
  validation_name STRING OPTIONS(description="Unique name of the validation"),
  validation_type STRING OPTIONS(description="Enum value of validation types [Column, GroupedColumn]"),
  start_time TIMESTAMP OPTIONS(description="Timestamp when the validation starts"),
  end_time TIMESTAMP OPTIONS(description="Timestamp when the validation finishes"),
  source_table_name STRING OPTIONS(description="Source table name with schema info"),
  target_table_name STRING OPTIONS(description="Target table name with schema info"),
  source_column_name STRING OPTIONS(description="Source column name"),
  target_column_name STRING OPTIONS(description="Target column name"),
  aggregation_type STRING OPTIONS(description="Aggregation type: count, min, max, avg, sum"),
  group_by_columns STRING OPTIONS(description="Group by columns, stored as a key-value JSON mapping"),
  primary_keys STRING OPTIONS(description="Primary keys for the validation"),
  num_random_rows INT64 OPTIONS(description="Number of random row batch size"),
  source_agg_value STRING OPTIONS(description="Source aggregation result, casted to a string"),
  target_agg_value STRING OPTIONS(description="Target aggregation result, casted to a string"),
  difference FLOAT64 OPTIONS(description="Difference between the source and target aggregation result (derived from target_agg_value and source_agg_value for convenience)"),
  pct_difference FLOAT64 OPTIONS(description="Percentage difference between the source and target aggregation result, based on source_agg_value."),
  pct_threshold FLOAT64 OPTIONS(description="Percentage difference threshold set by the user, based on source_agg_value."),
  validation_status STRING OPTIONS(description="Status of the validation. If the pct_difference is less than pc_threshold, it is considered as success. [success, fail]"),
  labels ARRAY<STRUCT<key STRING OPTIONS(description="Label key."), value STRING OPTIONS(description="Label value.")>> OPTIONS(description="Validation run labels."),
  configuration_json STRING OPTIONS(description="JSON representation of the validation metadata"),
  error_result STRUCT<code INT64 OPTIONS(description="Error code. See: https://cloud.google.com/apis/design/errors#handling_errors"), message STRING OPTIONS(description="A developer-facing error message, which should be in English."), details STRING OPTIONS(description="JSON-encoded information about the error(s).")> OPTIONS(description="Error info for debugging purpose")
)
PARTITION BY DATE(start_time)
CLUSTER BY validation_name, run_id;