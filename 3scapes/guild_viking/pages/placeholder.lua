-- Temporary stand-in for a stage-2 page module until its real page.lua lands
-- (Tasks 3-9). Page module contract: lines(width) -> array of strings, pure
-- (reads state.lua/page_opts.lua only, no ui.* calls, no mutation). Task 12's
-- audit removes this file once nothing in window.PAGES references it.
return {
  lines = function(width)
    return { "(page pending)" }
  end,
}
