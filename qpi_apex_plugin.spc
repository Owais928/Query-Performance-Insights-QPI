create or replace package qpi_apex_plugin as
  procedure render_region(
    p_region in apex_plugin.t_region,
    p_plugin in apex_plugin.t_plugin,
    p_param  in apex_plugin.t_region_render_param,
    p_result in out nocopy apex_plugin.t_region_render_result
  );

  procedure ajax_region(
    p_region in apex_plugin.t_region,
    p_plugin in apex_plugin.t_plugin,
    p_param  in apex_plugin.t_region_ajax_param,
    p_result in out nocopy apex_plugin.t_region_ajax_result
  );
end qpi_apex_plugin;
/
