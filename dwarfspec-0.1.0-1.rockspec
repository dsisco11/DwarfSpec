rockspec_format = "3.0"

package = "dwarfspec"
version = "0.1.0-1"

source = {
    url = "git+https://github.com/dsisco11/DwarfSpec.git",
    tag = "v0.1.0",
}

description = {
    summary = "In-process Busted automation for live DFHack interfaces.",
    detailed = [[
DwarfSpec runs Busted live-interface specifications inside DFHack while its
external command safely starts, observes, aborts, and reports those runs.
]],
    homepage = "https://github.com/dsisco11/DwarfSpec",
    license = "MIT",
}

dependencies = {
    "lua >= 5.3",
    "luasystem == 0.3.0-2",
    "busted == 2.3.0-1",
}

build = {
    type = "builtin",
    modules = {
        ["dwarfspec.cli"] = "src/dwarfspec/cli.lua",
        ["dwarfspec.component"] = "src/dwarfspec/component.lua",
        ["dwarfspec.config"] = "src/dwarfspec/config.lua",
        ["dwarfspec.glob"] = "src/dwarfspec/glob.lua",
        ["dwarfspec.layout"] = "src/dwarfspec/layout.lua",
        ["dwarfspec.process"] = "src/dwarfspec/process.lua",
        ["dwarfspec.project"] = "src/dwarfspec/project.lua",
        ["dwarfspec.report"] = "src/dwarfspec/report.lua",
        ["dwarfspec.runner"] = "src/dwarfspec/runner.lua",
        ["dwarfspec.ds"] = "tests/automation/support/ds.lua",
        ["dwarfspec.automation.abort"] = "tests/automation/abort.lua",
        ["dwarfspec.automation.bootstrap"] = "tests/automation/bootstrap.lua",
        ["dwarfspec.automation.probe"] = "tests/automation/probe.lua",
        ["dwarfspec.automation.status"] = "tests/automation/status.lua",
        ["dwarfspec.automation.cleanup"] = "tests/automation/support/cleanup.lua",
        ["dwarfspec.automation.diagnostics"] = "tests/automation/support/diagnostics.lua",
        ["dwarfspec.automation.extensions"] = "tests/automation/support/extensions.lua",
        ["dwarfspec.automation.fixture_loader"] = "tests/automation/support/fixture_loader.lua",
        ["dwarfspec.automation.host"] = "tests/automation/support/busted_host.lua",
        ["dwarfspec.automation.lfs_adapter"] = "tests/automation/support/lfs_adapter.lua",
        ["dwarfspec.automation.output_handler"] = "tests/automation/support/output_handler.lua",
        ["dwarfspec.automation.overlay_fixture"] = "tests/automation/support/overlay_fixture.lua",
        ["dwarfspec.automation.pointer_adapter"] = "tests/automation/support/pointer_adapter.lua",
        ["dwarfspec.automation.project"] = "tests/automation/support/project.lua",
        ["dwarfspec.automation.scheduler"] = "tests/automation/support/scheduler.lua",
        ["dwarfspec.automation.system_adapter"] = "tests/automation/support/system_adapter.lua",
    },
    install = {
        bin = {
            dwarfspec = "bin/dwarfspec",
            ["dwarfspec.bat"] = "bin/dwarfspec.bat",
        },
    },
}
