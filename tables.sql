create table qpi_run_log (
  id            number generated always as identity primary key,
  app_id        number,
  page_id       number,
  region_static_id varchar2(200),
  query_hash    varchar2(64),
  run_ts        timestamp default systimestamp,
  elapsed_ms    number,
  rows_returned number,
  plan_hash     number,
  notes         varchar2(4000)
);

create index qpi_run_log_i1 on qpi_run_log(app_id, page_id, region_static_id, query_hash, run_ts);

alter table qpi_run_log add (
  sql_id       varchar2(13),
  child_number number,
  plan_text    clob
);
