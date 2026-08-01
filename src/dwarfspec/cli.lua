-- Stable external-command facade for DwarfSpec.

local application = require('dwarfspec.controller.application')

return {
    version=application.version,
    main=application.main,
}
