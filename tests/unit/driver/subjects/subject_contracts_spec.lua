-- Unit contracts for subject sources and native/component control paths.

local ESubjectSource = require('dwarfspec.driver.subjects.subject_sources')
local subject_paths = require('dwarfspec.driver.subjects.subject_paths')
local subject_requests = require('dwarfspec.driver.subjects.subject_requests')

describe('DwarfSpec subject source and path contracts', function()
    it('defaults omitted root and tree requests to the native source',
            function()
        assert.same({
            source=ESubjectSource.NATIVE,
        }, subject_requests.root())
        assert.same({
            source=ESubjectSource.NATIVE,
        }, subject_requests.tree())
    end)

    it('accepts exact enum source members and overlay registry names',
            function()
        local native_root = {}
        assert.same({
            source=ESubjectSource.NATIVE,
        }, subject_requests.root({
            source=ESubjectSource.NATIVE,
        }))
        assert.same({
            source=ESubjectSource.NATIVE,
            native_root=native_root,
        }, subject_requests.root({
            native_root=native_root,
        }))
        assert.same({
            source=ESubjectSource.OVERLAY,
            overlay='gui/example.ExampleOverlay',
        }, subject_requests.tree({
            source=ESubjectSource.OVERLAY,
            overlay='gui/example.ExampleOverlay',
        }))
    end)

    it('rejects invalid source values and option combinations', function()
        assert.has_error(function()
            subject_requests.root({source='other'})
        end, 'unsupported subject source: other')
        assert.has_error(function()
            subject_requests.root({source=false})
        end, 'unsupported subject source: false')
        assert.has_error(function()
            subject_requests.root({
                source=ESubjectSource.OVERLAY,
            })
        end, 'overlay subject source requires an exact nonempty overlay name')
        assert.has_error(function()
            subject_requests.root({
                source=ESubjectSource.OVERLAY,
                overlay='',
            })
        end, 'overlay subject source requires an exact nonempty overlay name')
        assert.has_error(function()
            subject_requests.root({
                source=ESubjectSource.OVERLAY,
                overlay='gui/example.ExampleOverlay',
                native_root={},
            })
        end, 'native_root option conflicts with overlay subject source')
        assert.has_error(function()
            subject_requests.root({
                source=ESubjectSource.NATIVE,
                overlay='gui/example.ExampleOverlay',
            })
        end, 'overlay option conflicts with native subject source')
        assert.has_error(function()
            subject_requests.root({
                overlay='gui/example.ExampleOverlay',
            })
        end, 'overlay option conflicts with native subject source')
        assert.has_error(function()
            subject_requests.root({unknown=true})
        end, 'unsupported subject source option: unknown')
        assert.has_error(function()
            subject_requests.root(false)
        end, 'subject source options must be a table')
    end)

    it('preserves existing slash-delimited component paths', function()
        assert.same({'panel', 'list', 'row'},
            subject_paths.component('panel/list/row'))
        assert.has_error(function()
            subject_paths.component({'panel', 'list'})
        end, 'control path must be a nonempty string')
        assert.has_error(function()
            subject_paths.component('/panel')
        end, 'control path cannot start or end with "/"')
        assert.has_error(function()
            subject_paths.component('panel/')
        end, 'control path cannot start or end with "/"')
        assert.has_error(function()
            subject_paths.component('panel/../row')
        end, 'control path contains reserved segment ".."')
    end)

    it('normalizes simple native strings as one exact name', function()
        assert.same({'List'}, subject_paths.native('List'))
        assert.same({
            source=ESubjectSource.NATIVE,
            path_segments={'List'},
        }, subject_requests.get('List'))
        assert.has_error(function()
            subject_paths.native('')
        end, 'native control path must be a nonempty string or ' ..
            'path-segment array')
    end)

    it('preserves native segment arrays and zero-based indices exactly',
            function()
        local caller_path = {'Tabs', 0, 'Right/panel', 2}
        local normalized = subject_paths.native(caller_path)

        assert.same({'Tabs', 0, 'Right/panel', 2}, normalized)
        assert.is_not.equal(caller_path, normalized)
        caller_path[1] = 'changed'
        assert.equals('Tabs', normalized[1])

        local request = subject_requests.get(
            {'Tabs', 0, 'Right/panel'})
        assert.same({'Tabs', 0, 'Right/panel'}, request.path_segments)
        assert.equals(ESubjectSource.NATIVE, request.source)
    end)

    it('preserves slash-delimited paths for Lua overlay sources', function()
        local request = subject_requests.get('panel/list', {
            source=ESubjectSource.OVERLAY,
            overlay='gui/example.ExampleOverlay',
        })

        assert.same({'panel', 'list'}, request.path_segments)
        assert.equals(ESubjectSource.OVERLAY, request.source)
        assert.equals('gui/example.ExampleOverlay', request.overlay)
        assert.has_error(function()
            subject_requests.get({'panel', 'list'}, {
                source=ESubjectSource.OVERLAY,
                overlay='gui/example.ExampleOverlay',
            })
        end, 'control path must be a nonempty string')
    end)

    it('rejects ambiguous slash-bearing native string paths explicitly',
            function()
        assert.has_error(function()
            subject_paths.native('Tabs/Right panel')
        end, 'native string control path "Tabs/Right panel" is ambiguous ' ..
            'because native widget names may contain "/"; use path-segment ' ..
            'array syntax')
    end)

    it('rejects invalid native segment values and array shapes', function()
        local cases = {
            {
                path={''},
                expected='native control path segment 1 must be a nonempty ' ..
                    'string',
            },
            {
                path={-1},
                expected='native control path segment 1 must be a ' ..
                    'nonnegative integer',
            },
            {
                path={1.5},
                expected='native control path segment 1 must be a ' ..
                    'nonnegative integer',
            },
            {
                path={true},
                expected='native control path segment 1 must be a nonempty ' ..
                    'string or nonnegative integer; received boolean',
            },
            {
                path={},
                expected='native control path segment array must contain at ' ..
                    'least one segment',
            },
            {
                path={[1]='first', [3]='third'},
                expected='native control path segment array must not contain ' ..
                    'gaps',
            },
            {
                path={[0]='zero'},
                expected='native control path segment arrays must use ' ..
                    'positive integral array positions',
            },
            {
                path='parent/child',
                expected='native string control path "parent/child" is ' ..
                    'ambiguous',
            },
            {
                path=42,
                expected='native control path must be a nonempty string or ' ..
                    'path-segment array',
            },
        }
        for _, case in ipairs(cases) do
            local ok, failure = pcall(subject_paths.native, case.path)
            assert.is_false(ok)
            assert.matches(case.expected, failure, 1, true)
        end
    end)
end)
