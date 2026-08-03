package.path = '../../../../src/?.lua;../../../../src/?/init.lua;' .. package.path

local TestBed = require('dwarfspec.testbed')
local bed = TestBed.new()
local value = bed:require('value')
local script = bed:reqscript('worker')
bed:close()

assert(value == 7, 'zero-config module did not observe its script dependency')
assert(script.value == 7, 'zero-config script returned the wrong value')
io.write('ZERO_CONFIG_OK')
