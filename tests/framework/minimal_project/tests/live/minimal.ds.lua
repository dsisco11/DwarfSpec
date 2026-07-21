-- Product-independent live proof for the DwarfSpec consumer boundary.

local widgets = require('gui.widgets')

---@class tests.MinimalConsumerWidget: widgets.Panel
local MinimalConsumerWidget = defclass(nil, widgets.Panel)
MinimalConsumerWidget.ATTRS{
    view_id='minimal_root',
    frame={w=20, h=3},
}

---Builds one descendant for implicit selection and inspection.
function MinimalConsumerWidget:init()
    self:addviews{
        widgets.Label{
            view_id='status',
            frame={l=1, t=1, w=12},
            text='mounted',
        },
    }
end

describe('minimal DwarfSpec consumer', function()
    it('uses isolated commands and one implicit component mount', function()
        assert.is_nil(rawget(_G, 'ds'))
        assert.equals('minimal-consumer', ds.consumer_identity())

        local root = ds.mount(MinimalConsumerWidget)
        assert.equals('minimal_root', root:inspect().view_id)
        assert.equals('mounted', ds.get('status'):text())
        ds.unmount()
    end)
end)
