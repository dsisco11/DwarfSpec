-- Global settings and diagnostic adapters for the minimal consumer proof.

return {
    settings={
        wait={frame_budget=120, timeout_ms=5000},
    },
    diagnostics={
        render_generation=function(_, screen)
            return screen.render_generation
        end,
    },
}
