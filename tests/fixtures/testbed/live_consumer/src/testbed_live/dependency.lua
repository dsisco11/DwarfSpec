-- Consumer module whose identity must remain local to one TestBed.

local replacement = require('testbed_live.module_value')

return {
    identity={},
    replacement=replacement,
}
