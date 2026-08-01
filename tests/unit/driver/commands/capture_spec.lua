local command = require('dwarfspec.driver.commands.capture')

describe('capture command binding', function()
    it('stores a bounded capture under its validated name', function()
        local ds, run = {}, {}
        command.bind(ds, {run=run, diagnostics={capture_screen=function(options)
            return {options=options}
        end}})
        assert.same({options={rows=2}}, ds.capture_screen('example', {rows=2}))
        assert.same({options={rows=2}}, run.captures.example)
    end)
end)
