-- Unit contracts for safe project-local dotenv configuration.

local dotenv = require('dwarfspec.dotenv')

describe('DwarfSpec dotenv configuration', function()
    it('parses comments, exports, literal quotes, and inline comments',
            function()
        local values = dotenv.parse([[
# local machine configuration
DFHACK_ROOT="G:\Steam\Dwarf Fortress\hack"
export DFHACK_RUNNER='D:\DFHack\dfhack-run.exe'
EMPTY=
PLAIN=value # explanation
ESCAPED="line\nnext"
]], 'project/.env')
        assert.equals('G:\\Steam\\Dwarf Fortress\\hack',
            values.DFHACK_ROOT)
        assert.equals('D:\\DFHack\\dfhack-run.exe',
            values.DFHACK_RUNNER)
        assert.equals('', values.EMPTY)
        assert.equals('value', values.PLAIN)
        assert.equals('line\\nnext', values.ESCAPED)
    end)

    it('rejects malformed, duplicate, and unterminated assignments',
            function()
        assert.has_error(function()
            dotenv.parse('not an assignment', 'project/.env')
        end, 'malformed dotenv assignment at project/.env:1')
        assert.has_error(function()
            dotenv.parse('VALUE=one\nVALUE=two', 'project/.env')
        end, 'duplicate dotenv assignment for VALUE at project/.env:2')
        assert.has_error(function()
            dotenv.parse('VALUE="unfinished', 'project/.env')
        end, 'unterminated quoted value at project/.env:1')
    end)

    it('loads optional files and preserves real environment precedence',
            function()
        local files = {['project/.env']=true}
        local filesystem = {
            isfile=function(path) return files[path] == true end,
        }
        local values = dotenv.load('project/.env', filesystem,
            function() return 'FIRST=dotenv\nSECOND=fallback' end)
        local environment = dotenv.overlay({
            getenv=function(name)
                if name == 'FIRST' then return 'process' end
                if name == 'SECOND' then return '' end
                return nil
            end,
        }, values)
        assert.equals('process', environment.getenv('FIRST'))
        assert.equals('fallback', environment.getenv('SECOND'))
        assert.is_nil(environment.getenv('MISSING'))
        assert.same({}, dotenv.load('missing/.env', filesystem))
    end)
end)
