create or replace package body qpi_apex_plugin as

  function to_num(p_str varchar2, p_default number) return number is
  begin
    return to_number(trim(p_str));
  exception
    when others then return p_default;
  end;

  function yn(p_str varchar2, p_default varchar2) return varchar2 is
    l varchar2(1) := upper(nvl(trim(p_str), p_default));
  begin
    return case when l in ('Y','YES','1','T','TRUE') then 'Y' else 'N' end;
  end;

  function sha1(p_clob clob) return varchar2 is
    l_raw raw(2000);
  begin
    l_raw := dbms_crypto.hash(
      utl_i18n.string_to_raw(dbms_lob.substr(p_clob, 32767, 1), 'AL32UTF8'),
      dbms_crypto.hash_sh1
    );
    return lower(rawtohex(l_raw));
  exception
    when others then
      -- fallback for very large CLOB: hash first 32k only (still stable enough for dashboard)
      l_raw := dbms_crypto.hash(
        utl_i18n.string_to_raw(dbms_lob.substr(p_clob, 32000, 1), 'AL32UTF8'),
        dbms_crypto.hash_sh1
      );
      return lower(rawtohex(l_raw));
  end;

  function hash_query(p_clob clob) return varchar2 is
      l_v varchar2(32767);
      l_h varchar2(64);
    begin
      l_v := dbms_lob.substr(p_clob, 32000, 1);

      select lower(standard_hash(l_v, 'SHA256'))
        into l_h
        from dual;

      return l_h;
    end;

procedure ajax_region(
    p_region in apex_plugin.t_region,
    p_plugin in apex_plugin.t_plugin,
    p_param  in apex_plugin.t_region_ajax_param,
    p_result in out nocopy apex_plugin.t_region_ajax_result
  ) is
    l_sql_query   clob;
    l_sample_rows number;
    l_warn_ms     number;
    l_error_ms    number;
    l_plan_check  varchar2(1);
    l_save_hist   varchar2(1);

    l_query_hash  varchar2(64);

    l_start_ts    timestamp;
    l_end_ts      timestamp;
    l_elapsed_ms  number;

    l_rows        number := 0;
    l_plan_hash   number := null;

    l_dyn         clob;
    l_c           integer;
    l_exec        integer;

    l_app_id      number := v('APP_ID');
    l_page_id     number := v('APP_PAGE_ID');
    l_region_sid  varchar2(200) := nvl(p_region.static_id, 'QPI_'||p_region.id);

    l_status      varchar2(10) := 'good';
    l_prev_ms     number := null;
    l_prev_plan   number := null;
    l_marker      varchar2(2000);
    l_sql_id      varchar2(2000);
    l_child       number;
    l_plan_format varchar2(4000);
    l_plan_text   clob;
  begin
    -- Custom attributes
    l_sql_query  := p_region.attributes.get_varchar2('sql_query', p_do_substitutions => true);
    l_sample_rows:= to_num(p_region.attributes.get_varchar2('sample_rows'), 5000);
    l_warn_ms    := to_num(p_region.attributes.get_varchar2('warn_ms'), 800);
    l_error_ms   := to_num(p_region.attributes.get_varchar2('error_ms'), 2000);
    l_plan_check := yn(p_region.attributes.get_varchar2('plan_check'), 'Y');
    l_save_hist  := yn(p_region.attributes.get_varchar2('save_history'), 'Y');

    if l_sql_query is null then
      apex_json.open_object;
      apex_json.write('status','error');
      apex_json.write('message','SQL Query is required.');
      apex_json.close_object;
      return;
    end if;
    if regexp_like(l_sql_query, '\b(insert|update|delete|merge|drop|alter|truncate)\b', 'i') then
      apex_json.open_object;
      apex_json.write('status','error');
      apex_json.write('message','DML or DDL statements are not allowed.');
      apex_json.close_object;
      return;
    end if;

    l_query_hash := hash_query(l_sql_query);--sha1(l_sql_query);
    l_marker := '/*QPI:'||l_query_hash||':'||to_char(systimestamp,'YYYYMMDDHH24MISSFF3')||'*/';

    l_dyn := l_marker || chr(10) ||
      'with src as ('||chr(10)|| l_sql_query ||chr(10)||') '||
      'select count(*) CNT from (select * from src fetch first :SAMPLE_ROWS rows only)';

    l_start_ts := systimestamp;

    l_c := dbms_sql.open_cursor;
    dbms_sql.parse(l_c, l_dyn, dbms_sql.native);
    dbms_sql.bind_variable(l_c, ':SAMPLE_ROWS', l_sample_rows);
    dbms_sql.define_column(l_c, 1, l_rows);
    l_exec := dbms_sql.execute(l_c);
    if dbms_sql.fetch_rows(l_c) > 0 then
      dbms_sql.column_value(l_c, 1, l_rows);
    end if;
    dbms_sql.close_cursor(l_c);

    l_end_ts := systimestamp;
    l_elapsed_ms := round(extract(second from (l_end_ts - l_start_ts))*1000
                      + extract(minute from (l_end_ts - l_start_ts))*60*1000
                      + extract(hour   from (l_end_ts - l_start_ts))*3600*1000
                      + extract(day    from (l_end_ts - l_start_ts))*24*3600*1000);
                      
    begin
        select sql_id, child_number, plan_hash_value
          into l_sql_id, l_child, l_plan_hash
          from (
            select sql_id, child_number, plan_hash_value
              from v$sql
             where sql_text like l_marker||'%'
               and parsing_schema_name = sys_context('USERENV','CURRENT_SCHEMA')
             order by last_active_time desc
          )
         where rownum = 1;
      exception
        when others then
          l_sql_id := null;
          l_child  := null;
          l_plan_hash := null;
      end;

    -- Try to fetch last run for trend
    begin
      select elapsed_ms, plan_hash
        into l_prev_ms, l_prev_plan
        from (
          select elapsed_ms, plan_hash
            from qpi_run_log
           where app_id = l_app_id
             and page_id = l_page_id
             and region_static_id = l_region_sid
             and query_hash = l_query_hash
           order by run_ts desc
        )
       where rownum = 1;
    exception
      when no_data_found then null;
    end;

    -- Plan hash (optional, best-effort)
    if l_plan_check = 'Y' then
      begin
        -- Only works if query executed as SQL in cursor cache; best-effort.
        select max(plan_hash_value)
          into l_plan_hash
          from v$sql
         where sql_text like '%'||substr(replace(l_sql_query, chr(10),' '), 1, 80)||'%'
           and parsing_schema_name = sys_context('USERENV','CURRENT_SCHEMA');
      exception
        when others then
          l_plan_hash := null;
      end;
    end if;
    l_plan_format := nvl(p_region.attributes.get_varchar2('plan_format'), 'ALLSTATS LAST');
    -- Build plan text (if SQL_ID available)
    if l_sql_id is not null then
      begin
        select rtrim(
                 xmlcast(
                   xmlagg(xmlelement(e, plan_table_output || chr(10)) order by rownum)
                   as clob
                 ),
                 chr(10)
               ) as plan_text into l_plan_text
        from table(dbms_xplan.display_cursor(
          sql_id          => l_sql_id,
          cursor_child_no => l_child,
          format          => 'ALLSTATS LAST'
        ));
      exception
        when others then
          l_plan_text := null;
      end;
    end if;
    -- Status
    if l_elapsed_ms >= l_error_ms then
      l_status := 'bad';
    elsif l_elapsed_ms >= l_warn_ms then
      l_status := 'warn';
    else
      l_status := 'good';
    end if;

    -- Save history
    if l_save_hist = 'Y' then
      insert into qpi_run_log(app_id,page_id,region_static_id,query_hash,elapsed_ms,rows_returned,plan_hash)
      values (l_app_id,l_page_id,l_region_sid,l_query_hash,l_elapsed_ms,l_rows,l_plan_hash);
      commit;
    end if;

    -- JSON response
    apex_json.open_object;
    apex_json.write('status','ok');
    apex_json.write('elapsed_ms', l_elapsed_ms);
    apex_json.write('rows_returned', l_rows);
    apex_json.write('sample_rows', l_sample_rows);
    apex_json.write('plan_hash', l_plan_hash);
    apex_json.write('quality', l_status);
    apex_json.write('prev_elapsed_ms', l_prev_ms);
    apex_json.write('prev_plan_hash', l_prev_plan);
    apex_json.write('sql_id', l_sql_id);
    apex_json.write('child_number', l_child);
    apex_json.write('plan_hash', l_plan_hash);
    apex_json.write('plan_text', nvl(l_plan_text,'N/A'));

    apex_json.close_object;

  exception
    when others then
      if dbms_sql.is_open(l_c) then
        dbms_sql.close_cursor(l_c);
      end if;
      apex_json.open_object;
      apex_json.write('status','error');
      apex_json.write('message', sqlerrm);
      apex_json.close_object;
  end ajax_region;

  procedure render_region(
  p_region in apex_plugin.t_region,
  p_plugin in apex_plugin.t_plugin,
  p_param  in apex_plugin.t_region_render_param,
  p_result in out nocopy apex_plugin.t_region_render_result
) is
  l_region_id varchar2(200) := nvl(p_region.static_id, 'QPI_'||p_region.id);
  l_ajax_id   varchar2(4000) := apex_plugin.get_ajax_identifier;
begin
  -- Load CSS + JS properly
  apex_css.add_file(
    p_name      => 'qpi',
    p_directory => p_plugin.file_prefix
  );

  apex_javascript.add_library(
    p_name      => 'qpi',
    p_directory => p_plugin.file_prefix
  );

  -- Region container
  htp.p(
    '<div class="qpi" id="'||apex_escape.html_attribute(l_region_id)||'">'||
    '<div class="qpi-loading">Measuring query performance…</div>'||
    '</div>'
  );

  -- Safe delayed initialization
  htp.p(
    '<script>'||
    '(function(){'||
    '  var rid='||apex_escape.js_literal(l_region_id)||';'||
    '  var ajax='||apex_escape.js_literal(l_ajax_id)||';'||
    '  function waitQPI(){'||
    '    if(window.QPI && typeof window.QPI.init === "function"){'||
    '      window.QPI.init({regionId: rid, ajaxId: ajax});'||
    '    } else {'||
    '      setTimeout(waitQPI, 50);'||
    '    }'||
    '  }'||
    '  waitQPI();'||
    '})();'||
    '</script>'
  );
end render_region;
  
end qpi_apex_plugin;
/
