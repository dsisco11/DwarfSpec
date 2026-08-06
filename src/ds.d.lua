---@meta

---@alias dwarfspec.EPointerAnchor
---| 'center'
---| 'top_left'
---| 'top_right'
---| 'bottom_left'
---| 'bottom_right'

---@alias dwarfspec.PointerAnchor dwarfspec.EPointerAnchor

---@alias dwarfspec.MouseButton
---| 'left'
---| 'right'
---| 'middle'

---@alias dwarfspec.EMouseButton
---| 'left'
---| 'right'
---| 'middle'
---| 'scroll_up'
---| 'scroll_down'

---@alias dwarfspec.EInputState
---| 'click'
---| 'down'
---| 'up'

---A supported DFHack state-change event identifier.
---@alias dwarfspec.EEvent
---| 'world_loaded'
---| 'world_unloaded'
---| 'map_loaded'
---| 'map_unloaded'
---| 'viewscreen_changed'
---| 'paused'
---| 'unpaused'

---The `ds.EPointerSpace.GRID` coordinate-space value.
---@alias dwarfspec.GridPointerSpace 1

---The `ds.EPointerSpace.PIXELS` coordinate-space value.
---@alias dwarfspec.PixelPointerSpace 2

---The `ds.EPointerSpace.WORLD_TILE` coordinate-space value.
---@alias dwarfspec.WorldTilePointerSpace 3

---A pointer coordinate space obtained from `ds.EPointerSpace`.
---@alias dwarfspec.EPointerSpace dwarfspec.GridPointerSpace|dwarfspec.PixelPointerSpace|dwarfspec.WorldTilePointerSpace

---@alias dwarfspec.EScreenOrigin
---| 'top_left'
---| 'top'
---| 'top_right'
---| 'left'
---| 'center'
---| 'right'
---| 'bottom_left'
---| 'bottom'
---| 'bottom_right'

---@alias dwarfspec.ESubjectSource
---| 'native'
---| 'overlay'

---@alias dwarfspec.ECommandKind
---| 'query'
---| 'assertion'
---| 'action'
---| 'state_setter'
---| 'workflow'
---| 'fixture'

---@alias dwarfspec.EIntrinsicVerificationKind
---| 'primary_observation'
---| 'callback'
---| 'execution_receipt'

---@alias dwarfspec.EExecutionRetryPolicy
---| 'once'
---| 'explicit_retry_safe'

---@alias dwarfspec.EExecutionOwnerScope
---| 'service_run'
---| 'suite_execution'
---| 'test_attempt'

---@alias dwarfspec.ECleanupOwnerScope dwarfspec.EExecutionOwnerScope
---@alias dwarfspec.ECleanupLifetime 'owner'|'command'
---@alias dwarfspec.ECleanupState 'pending'|'running'|'complete'|'failed'|'abandoned'|'unconfirmed'
---@alias dwarfspec.ECleanupTerminalDisposition 'complete'|'failed'|'abandoned'|'unconfirmed'
---@alias dwarfspec.ECleanupExecutionTrigger 'manual'|'command_finally'|'owner_teardown'
---@alias dwarfspec.ECommandFailureStage 'normalization'|'preflight'|'claim_planning'|'execution'|'cleanup_registration'|'intrinsic_verification'|'caller_verification'|'command_cleanup'|'result_projection'

---Read-only data supplied to optional caller verification.
---@class dwarfspec.CommandObservation
---@field name string
---@field kind dwarfspec.ECommandKind
---@field target_identity? string
---@field result any
---@field receipt any
---@field attempt_count integer
---@field elapsed_ms integer
---@field remaining_ms integer
---@field intrinsic_evidence any

---Trailing options shared by every public command.
---@class dwarfspec.CommandOptions
---@field timeout_ms? integer Positive finite wall-clock timeout.
---@field description? string
---@field verify? fun(observation: dwarfspec.CommandObservation): any

---@class dwarfspec.CommandReadContext
---@field now_ms fun(self: dwarfspec.CommandReadContext): number
---@field remaining_ms fun(self: dwarfspec.CommandReadContext): integer
---@field cancellation fun(self: dwarfspec.CommandReadContext): boolean, string|nil
---@field resolve_mount fun(self: dwarfspec.CommandReadContext, ...: any): any
---@field resolve_target fun(self: dwarfspec.CommandReadContext, ...: any): any
---@field lookup_claim fun(self: dwarfspec.CommandReadContext, reference: any): table|nil
---@field capture_render fun(self: dwarfspec.CommandReadContext): any
---@field observe_render fun(self: dwarfspec.CommandReadContext, generation: any): any
---@field record_diagnostic fun(self: dwarfspec.CommandReadContext, kind: string, evidence: table): any
---@field identity fun(self: dwarfspec.CommandReadContext): dwarfspec.CommandIdentity
---@field invoke_readonly fun(self: dwarfspec.CommandReadContext, kind: dwarfspec.ECommandKind, name: string, ...: any): any

---@class dwarfspec.CommandExecutionContext
---@field now_ms fun(self: dwarfspec.CommandExecutionContext): number
---@field remaining_ms fun(self: dwarfspec.CommandExecutionContext): integer
---@field cancellation fun(self: dwarfspec.CommandExecutionContext): boolean, string|nil
---@field wait_frames fun(self: dwarfspec.CommandExecutionContext, count: integer): any
---@field wait_ticks fun(self: dwarfspec.CommandExecutionContext, count: integer): any
---@field wait_event fun(self: dwarfspec.CommandExecutionContext, event: string, options?: table): any
---@field wait_until fun(self: dwarfspec.CommandExecutionContext, description: string, predicate: fun(): any): any
---@field execute_step fun(self: dwarfspec.CommandExecutionContext, step: dwarfspec.WorkflowStepDefinition, state: dwarfspec.WorkflowState): any

---@class dwarfspec.CommandIdentity
---@field invocation_id string
---@field root_invocation_id string
---@field parent_invocation_id? string
---@field parent_cleanup_transaction_id? string
---@field owner_scope dwarfspec.EExecutionOwnerScope
---@field service_run_id string
---@field suite_execution_id? string
---@field test_attempt_id? string
---@field target_identity? string
---@field cleanup_checkpoint integer
---@field current_stage string

---@class dwarfspec.CleanupRegistrationCapability
---@field register fun(self: dwarfspec.CleanupRegistrationCapability, registration: dwarfspec.CleanupRegistration): dwarfspec.CleanupTransaction

---@class dwarfspec.PrivilegedCommandExecutionContext: dwarfspec.CommandExecutionContext
---@field cleanup_registration fun(self: dwarfspec.PrivilegedCommandExecutionContext): dwarfspec.CleanupRegistrationCapability

---@class dwarfspec.CleanupExecutionContext
---@field remaining_ms fun(self: dwarfspec.CleanupExecutionContext): integer
---@field observe fun(self: dwarfspec.CleanupExecutionContext, name: string, ...: any): any

---@class dwarfspec.GateResult
---@field kind 'ready'|'pending'|'fatal'
---@field value? any
---@field message? string
---@field evidence? table

---@class dwarfspec.ExecutionResult
---@field kind 'executed'|'retry'|'failed'
---@field public_result? any Present on an executed outcome.
---@field receipt? any Private evidence for an executed outcome.
---@field effect_receipt? any
---@field attempt_receipt? any Required when retry reports an attempted effect.
---@field reason? string Required for a retry outcome.
---@field message? string
---@field evidence? table

---@class dwarfspec.IntrinsicVerificationResult
---@field kind 'ready'|'pending'|'fatal'|'effect_absent'
---@field message? string
---@field evidence? table

---@class dwarfspec.ResourceClaimReference
---@field claim_id string
---@field transaction_id string
---@field service_run_id string

---@class dwarfspec.ResourceClaimPlanEntry
---@field claim_key string
---@field resource_kind string
---@field resource_identity string
---@field exclusive boolean
---@field provisional? boolean
---@field depends_on_claim_keys? string[]
---@field depends_on_references? dwarfspec.ResourceClaimReference[]
---@field shares_with_references? dwarfspec.ResourceClaimReference[]
---@field consumes_references? dwarfspec.ResourceClaimReference[]

---@class dwarfspec.ResourceClaimBinding
---@field claim_key string
---@field resource_identity string

---@class dwarfspec.ResourceClaimRegistration
---@field claim_key string
---@field resource_kind string
---@field resource_identity string
---@field exclusive boolean
---@field depends_on_claim_keys? string[]
---@field depends_on_references? dwarfspec.ResourceClaimReference[]
---@field shares_with_references? dwarfspec.ResourceClaimReference[]
---@field consumes_references? dwarfspec.ResourceClaimReference[]

---Run-scoped policy state for active cleanup-backed resource claims.
---@class dwarfspec.ResourceDependencyIndex
---@field new fun(service_run_id: string, release_authorizer?: fun(transaction_id: string, proof: any): string): dwarfspec.ResourceDependencyIndex
---@field validate_plan fun(self: dwarfspec.ResourceDependencyIndex, owner: dwarfspec.ExecutionOwnerIdentity, invocation_id: string, lifetime: dwarfspec.ECleanupLifetime, entries: dwarfspec.ResourceClaimPlanEntry[], operation_key?: string, consumption_authorization?: table): table
---@field consumption_authorization fun(self: dwarfspec.ResourceDependencyIndex, definition: dwarfspec.CommandDefinition): table
---@field activate fun(self: dwarfspec.ResourceDependencyIndex, plan: table, transaction_id: string, bindings: dwarfspec.ResourceClaimBinding[]): dwarfspec.ResourceClaimReference[]
---@field register fun(self: dwarfspec.ResourceDependencyIndex, owner: dwarfspec.ExecutionOwnerIdentity, transaction_id: string, lifetime: dwarfspec.ECleanupLifetime, registrations: dwarfspec.ResourceClaimRegistration[]): dwarfspec.ResourceClaimReference[]
---@field lookup fun(self: dwarfspec.ResourceDependencyIndex, reference: dwarfspec.ResourceClaimReference): table
---@field references_for_transaction fun(self: dwarfspec.ResourceDependencyIndex, transaction_id: string): dwarfspec.ResourceClaimReference[]
---@field dependent_transaction_ids fun(self: dwarfspec.ResourceDependencyIndex, transaction_id: string): string[]
---@field record_conflicted_registration fun(self: dwarfspec.ResourceDependencyIndex, transaction_id: string, owner: dwarfspec.ExecutionOwnerIdentity, evidence: table): table
---@field retain_unresolved fun(self: dwarfspec.ResourceDependencyIndex, transaction_id: string)
---@field transfer fun(self: dwarfspec.ResourceDependencyIndex, reference: dwarfspec.ResourceClaimReference, owner: dwarfspec.ExecutionOwnerIdentity, transaction_id: string): dwarfspec.ResourceClaimReference
---@field release_verified fun(self: dwarfspec.ResourceDependencyIndex, transaction_id: string, proof: any)

---@class dwarfspec.CleanupRegistration
---@field label string
---@field receipt table
---@field restore fun(context: dwarfspec.CleanupExecutionContext, receipt: table)
---@field verify fun(context: dwarfspec.CleanupExecutionContext, receipt: table): boolean|dwarfspec.GateResult|nil
---@field cleanup_timeout_ms? integer
---@field resources? dwarfspec.ResourceClaimRegistration[]

---@class dwarfspec.CleanupTransaction
---@field execute fun(self: dwarfspec.CleanupTransaction, reason?: string): boolean
---@field isPending fun(self: dwarfspec.CleanupTransaction): boolean
---@field claimReferences fun(self: dwarfspec.CleanupTransaction): dwarfspec.ResourceClaimReference[]

---Run-scoped authority for atomic cleanup transaction registration and history.
---@class dwarfspec.CleanupRegistrationService
---@field new fun(options: table): dwarfspec.CleanupRegistrationService
---@field register fun(self: dwarfspec.CleanupRegistrationService, registration: table): dwarfspec.CleanupTransaction
---@field abandonSelfRolledBack fun(self: dwarfspec.CleanupRegistrationService, transaction_id: string, mutation_lease: dwarfspec.CleanupMutationLease, proof: table)
---@field journal fun(self: dwarfspec.CleanupRegistrationService): table[]
---@field pending_ids_for fun(self: dwarfspec.CleanupRegistrationService, owner: dwarfspec.ExecutionOwnerIdentity): table<string, true>

---Runner-owned lease that serializes one mutating command attempt.
---@class dwarfspec.CleanupMutationLease
---@field release fun(self: dwarfspec.CleanupMutationLease)

---@class dwarfspec.CleanupExecutionContext
---@field remaining_ms fun(self: dwarfspec.CleanupExecutionContext): integer
---@field cancellation fun(self: dwarfspec.CleanupExecutionContext): boolean, string|nil
---@field record_diagnostic fun(self: dwarfspec.CleanupExecutionContext, kind: string, evidence: table): table
---@field invoke_readonly fun(self: dwarfspec.CleanupExecutionContext, kind: dwarfspec.ECommandKind, name: string, ...: any): any

---@class dwarfspec.ExecutionOwnerIdentity
---@field owner_scope dwarfspec.EExecutionOwnerScope
---@field service_run_id string
---@field suite_execution_id? string
---@field test_attempt_id? string

---@class dwarfspec.CleanupOwnerIdentity
---@field owner_scope dwarfspec.ECleanupOwnerScope
---@field service_run_id string
---@field suite_execution_id? string
---@field test_attempt_id? string

---@class dwarfspec.CleanupTransactionResult: dwarfspec.CleanupOwnerIdentity
---@field transaction_id string
---@field registration_ordinal integer
---@field label string
---@field lifetime dwarfspec.ECleanupLifetime
---@field disposition dwarfspec.ECleanupTerminalDisposition
---@field registered_at_ms number
---@field completed_at_ms number
---@field command_invocation_id? string
---@field restore_outcome? string
---@field verification_outcome? string
---@field failure_reference? string
---@field evidence? table

---@class dwarfspec.CleanupLifecycleEvent: dwarfspec.CleanupOwnerIdentity
---@field event_type 'cleanup.transaction_registered'|'cleanup.transaction_started'|'cleanup.transaction_finished'|'cleanup.transaction_abandoned'
---@field transaction_id string
---@field registration_ordinal integer
---@field label string
---@field lifetime dwarfspec.ECleanupLifetime
---@field state dwarfspec.ECleanupState
---@field trigger? dwarfspec.ECleanupExecutionTrigger
---@field command_invocation_id? string
---@field repeat_index? integer
---@field spec_file_identity? string
---@field test_identity? string
---@field registered_at_ms number
---@field execution_started_at_ms? number
---@field completed_at_ms? number
---@field restore_outcome? string
---@field verification_outcome? string
---@field disposition? dwarfspec.ECleanupTerminalDisposition
---@field evidence? table
---@field failure_reference? string

---@class dwarfspec.SuiteExecutionResult
---@field service_run_id string
---@field suite_execution_id string
---@field repeat_index integer
---@field spec_file_identity string
---@field behavior_summary table
---@field cleanup_outcome string
---@field cleanup_transactions dwarfspec.CleanupTransactionResult[]

---@class dwarfspec.TestAttemptResult
---@field service_run_id string
---@field suite_execution_id string
---@field test_attempt_id string
---@field repeat_index integer
---@field test_identity string
---@field cleanup_transactions dwarfspec.CleanupTransactionResult[]

---@class dwarfspec.VerifiedExecutionHostReport
---@field schema `dwarfspec.result.v3`
---@field protocol_version 3
---@field service_run_id string
---@field service_cleanup_transactions dwarfspec.CleanupTransactionResult[]
---@field suite_executions dwarfspec.SuiteExecutionResult[]
---@field test_attempts dwarfspec.TestAttemptResult[]

---@class dwarfspec.CommandCleanupPolicy
---@field lifetime dwarfspec.ECleanupLifetime
---@field restore fun(context: dwarfspec.CleanupExecutionContext, receipt: any)
---@field verify fun(context: dwarfspec.CleanupExecutionContext, receipt: any): boolean|dwarfspec.GateResult|nil
---@field resources? fun(receipt: any): dwarfspec.ResourceClaimBinding[]
---@field allow_cross_owner_consumption? boolean

---@class dwarfspec.WorkflowOutput
---@field has_value boolean
---@field value? any

---@class dwarfspec.WorkflowState
---@field request any
---@field outputs table<string, dwarfspec.WorkflowOutput>

---@class dwarfspec.WorkflowStepDefinition
---@field name string
---@field kind dwarfspec.ECommandKind
---@field preflight fun(context: dwarfspec.CommandReadContext, state: dwarfspec.WorkflowState): dwarfspec.GateResult
---@field claims? fun(context: dwarfspec.CommandReadContext, state: dwarfspec.WorkflowState, ready: any): dwarfspec.ResourceClaimPlanEntry[]
---@field execute fun(context: dwarfspec.CommandExecutionContext, state: dwarfspec.WorkflowState, ready: any): dwarfspec.ExecutionResult|dwarfspec.GateResult
---@field execution_retry_policy dwarfspec.EExecutionRetryPolicy
---@field operation_key? fun(state: dwarfspec.WorkflowState): string
---@field intrinsic_verification dwarfspec.EIntrinsicVerificationKind
---@field verify? fun(context: dwarfspec.CommandReadContext, state: dwarfspec.WorkflowState, receipt: any): dwarfspec.IntrinsicVerificationResult
---@field cleanup? dwarfspec.CommandCleanupPolicy
---@field diagnostics? fun(state: dwarfspec.WorkflowState, receipt: any): table

---@class dwarfspec.WorkflowDefinition
---@field steps dwarfspec.WorkflowStepDefinition[]
---@field result fun(state: dwarfspec.WorkflowState): any

---@class dwarfspec.CommandDefinition
---@field name string
---@field kind dwarfspec.ECommandKind
---@field normalize fun(arguments: table): any
---@field preflight fun(context: dwarfspec.CommandReadContext, request: any): dwarfspec.GateResult
---@field claims? fun(context: dwarfspec.CommandReadContext, request: any, ready: any): dwarfspec.ResourceClaimPlanEntry[]
---@field execute? fun(context: dwarfspec.CommandExecutionContext, request: any, ready: any): dwarfspec.ExecutionResult|dwarfspec.GateResult
---@field workflow? dwarfspec.WorkflowDefinition
---@field execution_retry_policy dwarfspec.EExecutionRetryPolicy
---@field operation_key? fun(request: any): string
---@field intrinsic_verification dwarfspec.EIntrinsicVerificationKind
---@field verify? fun(context: dwarfspec.CommandReadContext, request: any, receipt: any): dwarfspec.IntrinsicVerificationResult
---@field cleanup? dwarfspec.CommandCleanupPolicy
---@field default_timeout_ms? integer
---@field diagnostics? fun(request: any, receipt: any): table

---A declared game-UI field, exact widget name, or zero-based widget index.
---@alias dwarfspec.NativePathSegment string|integer
---A nonempty native path. Declared fields may precede exact widget segments.
---@alias dwarfspec.NativePath dwarfspec.NativePathSegment[]

---@class dwarfspec.EMouseButtonEnum
---@field LEFT `left`
---@field RIGHT `right`
---@field MIDDLE `middle`
---@field SCROLL_UP `scroll_up`
---@field SCROLL_DOWN `scroll_down`

---@class dwarfspec.EInputStateEnum
---@field CLICK `click`
---@field DOWN `down`
---@field UP `up`

---Immutable identifiers for state-change events supported by `awaitEvent()`.
---@class dwarfspec.EEventEnum
---@field WORLD_LOADED `world_loaded`
---@field WORLD_UNLOADED `world_unloaded`
---@field MAP_LOADED `map_loaded`
---@field MAP_UNLOADED `map_unloaded`
---@field VIEWSCREEN_CHANGED `viewscreen_changed`
---@field PAUSED `paused`
---@field UNPAUSED `unpaused`

---Immutable pointer coordinate spaces. Use these members instead of backing
---values: `GRID` addresses UI-grid cells, `PIXELS` addresses screen pixels,
---and `WORLD_TILE` addresses map tiles.
---@class dwarfspec.EPointerSpaceEnum
---@field GRID dwarfspec.GridPointerSpace Zero-based UI-grid cells; the default.
---@field PIXELS dwarfspec.PixelPointerSpace Exact zero-based screen pixels.
---@field WORLD_TILE dwarfspec.WorldTilePointerSpace Zero-based world-map tiles.

---Immutable anchors for pointer placement within subject bounds.
---@class dwarfspec.EPointerAnchorEnum
---@field CENTER `center`
---@field TOP_LEFT `top_left`
---@field TOP_RIGHT `top_right`
---@field BOTTOM_LEFT `bottom_left`
---@field BOTTOM_RIGHT `bottom_right`

---Immutable map viewport anchors used by `getViewPos()` and `setViewPos()`.
---@class dwarfspec.EScreenOriginEnum
---@field TOP_LEFT `top_left`
---@field TOP `top`
---@field TOP_RIGHT `top_right`
---@field LEFT `left`
---@field CENTER `center`
---@field RIGHT `right`
---@field BOTTOM_LEFT `bottom_left`
---@field BOTTOM `bottom`
---@field BOTTOM_RIGHT `bottom_right`

---Immutable identifiers for inspectable native and registered-overlay sources.
---@class dwarfspec.ESubjectSourceEnum
---@field NATIVE `native`
---@field OVERLAY `overlay`

---Selects the borrowed native hierarchy, which is the default source.
---@class dwarfspec.NativeSubjectSourceOptions
---@field source? `native`
---@field overlay? nil
---@field native_root? userdata Advanced exact-root bypass for ambiguity or unsupported DF structures.

---Selects one externally owned widget from DFHack's live overlay registry.
---@class dwarfspec.OverlaySubjectSourceOptions
---@field source `overlay`
---@field overlay string Exact enabled overlay registry name.
---@field native_root? nil

---@alias dwarfspec.SubjectSourceOptions dwarfspec.NativeSubjectSourceOptions|dwarfspec.OverlaySubjectSourceOptions
---@alias dwarfspec.RootSourceOptions dwarfspec.SubjectSourceOptions
---@alias dwarfspec.GetSourceOptions dwarfspec.SubjectSourceOptions
---@alias dwarfspec.CaptureViewTreeSourceOptions dwarfspec.SubjectSourceOptions

---@class dwarfspec.WaitOptions
---@field timeout_ms? integer
---@field frame_budget? integer
---@field description? string

---@class dwarfspec.TickWaitOptions
---@field timeout_ms? integer Maximum wall-clock time in milliseconds before the wait fails; defaults to settings.wait.timeout_ms or 10000.
---@field description? string Operation name included in timeout diagnostics; defaults to `wait_ticks(count)`.

---Options for awaiting the next supported DFHack state-change event.
---@class dwarfspec.EventWaitOptions
---@field trigger? fun() Invoked after the native listener is armed; a matching synchronous event is captured.
---@field description? string Nonempty operation name included in diagnostics.
---@field timeout_ms? integer|false Positive command-local timeout in milliseconds; `false` or omission disables it.

---Normalized immutable payload captured while native event data is valid.
---Unavailable fields are omitted.
---@class dwarfspec.EventPayload
---@field save_directory? string Loaded or previously loaded save-directory name for world and map events.
---@field focus? string Current native focus for a viewscreen change.
---@field native_screen_type? string Current native screen type for a viewscreen change.
---@field paused? boolean Current pause state for pause and unpause events.

---Immutable snapshot of one supported DFHack event occurrence.
---@class dwarfspec.EventOccurrence
---@field event dwarfspec.EEvent Public event identifier that matched the wait.
---@field source `state_change` Fixed native event source.
---@field payload dwarfspec.EventPayload Normalized payload without transient native pointers.

---@class dwarfspec.RedrawOptions
---@field wait? boolean Wait for the resulting completed render; defaults to true.

---@class dwarfspec.WorldTilePointerOptions
---@field recenter? boolean Recenter the map view on the tile before moving; defaults to true.

---@class dwarfspec.Viewport
---@field width integer
---@field height integer

---@class dwarfspec.MapViewPosition
---@field x integer Map-tile x coordinate at the selected screen origin.
---@field y integer Map-tile y coordinate at the selected screen origin.
---@field z integer Zero-based map z-level.

---@class dwarfspec.OverlayPosition
---@field x integer
---@field y integer

---@class dwarfspec.MountOptions
---@field viewport? dwarfspec.Viewport
---@field backing_viewscreen? table
---@field overlay_position? dwarfspec.OverlayPosition
---@field fullscreen? boolean
---@field full_interface? boolean
---@field [string] any

---@class dwarfspec.ScreenCaptureOptions
---@field max_width? integer
---@field max_height? integer

---A zero-based inclusive rectangle in absolute UI-grid coordinates.
---@class (exact) dwarfspec.ScreenRect
---@field x1 integer Leftmost included UI-grid column.
---@field y1 integer Topmost included UI-grid row.
---@field x2 integer Rightmost included UI-grid column.
---@field y2 integer Bottommost included UI-grid row.

---A subject inspection rectangle with optional window-clipped coordinates.
---@class dwarfspec.SubjectInspectRect: dwarfspec.ScreenRect
---@field clip_x1? integer
---@field clip_y1? integer
---@field clip_x2? integer
---@field clip_y2? integer

---An exact rendered-text query.
---Text is a nonempty, single-row CP437 or byte string matched literally and
---case-sensitively. Occurrences are counted top-to-bottom, then left-to-right.
---@class (exact) dwarfspec.TextSearchQuery
---@field text string Text to match; NUL, carriage-return, and newline bytes are invalid.
---@field occurrence? integer Positive occurrence number; defaults to 1.

---A spatial rendered-text search area.
---A subject contributes only its current visible body bounds and does not
---prove that the subject painted any matching screen cell.
---@alias dwarfspec.TextSearchArea dwarfspec.Subject|dwarfspec.ScreenRect

---@class dwarfspec.SubjectInspectState
---@field class string
---@field view_id string|nil
---@field visible boolean
---@field active boolean
---@field focused boolean
---@field frame dwarfspec.SubjectInspectRect|nil
---@field body dwarfspec.SubjectInspectRect|nil
---@field text string|nil
---@field tooltip string|nil
---@field native_type? string Native DF widget type for native subjects.
---@field name? string Native widget name for native subjects.
---@field effective_visible? boolean Visibility including native ancestors.
---@field effective_active? boolean Activity including native ancestors.
---@field scroll_position? integer Native scroll-row position.
---@field visible_row_count? integer Native scroll-row visible count.
---@field selected_index? integer Native tabs, dropdown, or radio selection.

---@class dwarfspec.ScreenCell
---@field ch? integer
---@field fg? integer
---@field bg? integer
---@field bold? boolean
---@field tile? integer

---@class dwarfspec.ScreenCapture
---@field width integer
---@field height integer
---@field cells table<integer, table<integer, dwarfspec.ScreenCell|nil>>

---@class dwarfspec.Subject
local Subject = {}

---@class dwarfspec.MouseWheelOptions
---@field direction dwarfspec.EMouseButton
---@field steps? integer Defaults to one discrete wheel input.
---@field anchor? dwarfspec.EPointerAnchor

---Clicks this subject and preserves it for fluent chaining.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---It does not reverse game or UI effects caused by the click.
---@param button? dwarfspec.MouseButton
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.Subject
function Subject:click(button, command_options) end

---Moves the pointer over this subject in UI-grid cells and preserves it.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---@param anchor? dwarfspec.EPointerAnchor
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.Subject
function Subject:hover(anchor, command_options) end

---Moves the pointer to this subject in UI-grid cells and preserves it.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---@param anchor? dwarfspec.EPointerAnchor
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.Subject
function Subject:move_pointer(anchor, command_options) end

---Sends a discrete wheel-input batch over this subject and preserves it.
---Only the render after the complete batch is awaited.
---@param options dwarfspec.MouseWheelOptions
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.Subject
function Subject:mouseWheel(options, command_options) end

---Sends native input through this subject's mounted screen.
---@param keys string|string[]|table
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.Subject
function Subject:input(keys, command_options) end

---Types ASCII text through this subject's mounted screen.
---@param text string
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.Subject
function Subject:type(text, command_options) end

---Redraws this subject's mounted screen and waits by default.
---@param options? dwarfspec.RedrawOptions
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.Subject
function Subject:redraw(options, command_options) end

---Returns a stable diagnostic snapshot of this subject.
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.SubjectInspectState
function Subject:inspect(command_options) end

---Searches the final rendered buffer within this subject's visible body.
---Matching is literal and case-sensitive. Occurrences are counted
---top-to-bottom, then left-to-right. A match returns exact zero-based
---inclusive UI-grid bounds; an ordinary readable miss returns nil. The
---operation fails when the entire effective region is unreadable.
---Subject scoping is spatial and does not prove which view painted a match.
---@param query dwarfspec.TextSearchQuery
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.ScreenRect|nil
function Subject:search(query, command_options) end

---Returns a copied focus-string list for this subject's current mounted screen.
---@param command_options? dwarfspec.CommandOptions
---@return string[]
function Subject:getFocusList(command_options) end

---Returns the stable inspected text value for this subject.
---@param command_options? dwarfspec.CommandOptions
---@return string|nil
function Subject:text(command_options) end

---Returns the exact Lua view table or typed native DF userdata for this subject.
---The returned object is borrowed and becomes invalid with its subject.
---@param command_options? dwarfspec.CommandOptions
---@return table|userdata
function Subject:raw(command_options) end

---@class dwarfspec.DS
---@field protocol_version integer
---@field EEvent dwarfspec.EEventEnum
---@field EMouseButton dwarfspec.EMouseButtonEnum
---@field EInputState dwarfspec.EInputStateEnum
---@field EPointerSpace dwarfspec.EPointerSpaceEnum
---@field EPointerAnchor dwarfspec.EPointerAnchorEnum
---@field EScreenOrigin dwarfspec.EScreenOriginEnum
---@field ESubjectSource dwarfspec.ESubjectSourceEnum
local DS = {}

---Waits for actual DFHack raw-frame callbacks without blocking the game.
---@param count integer
---@param options? dwarfspec.WaitOptions
---@param command_options? dwarfspec.CommandOptions
---@return integer
function DS.wait_frames(count, options, command_options) end

---Waits for unpaused Dwarf Fortress simulation ticks without blocking.
---@param count integer
---@param options? dwarfspec.TickWaitOptions
---@param command_options? dwarfspec.CommandOptions
---@return integer
function DS.wait_ticks(count, options, command_options) end

---Polls a read-only condition once per frame until it becomes ready.
---@generic T
---@param description string
---@param query fun():T|nil|false
---@param options? dwarfspec.WaitOptions
---@param command_options? dwarfspec.CommandOptions
---@return T
function DS.await(description, query, options, command_options) end

---Waits for the next matching event, even when its associated state is already
---true. The native listener is armed before an optional trigger runs, so an
---event raised synchronously by the trigger is captured. No command-local
---timeout is imposed unless `timeout_ms` is explicitly provided.
---@param event dwarfspec.EEvent
---@param options? dwarfspec.EventWaitOptions
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.EventOccurrence
function DS.awaitEvent(event, options, command_options) end

---Returns whether the Dwarf Fortress simulation is currently paused.
---@param command_options? dwarfspec.CommandOptions
---@return boolean
function DS.isGamePaused(command_options) end

---Sets the game pause state for the current example.
---DwarfSpec automatically restores the inherited state during cleanup.
---@param paused boolean
---@param command_options? dwarfspec.CommandOptions
---@return boolean
function DS.setGamePaused(paused, command_options) end

---Returns the current game ticks-per-second target.
---@param command_options? dwarfspec.CommandOptions
---@return integer
function DS.getGameSpeed(command_options) end

---Sets the game ticks-per-second target for the current example.
---DwarfSpec automatically restores the inherited state during cleanup.
---@param tps integer
---@param command_options? dwarfspec.CommandOptions
---@return integer
function DS.setGameSpeed(tps, command_options) end

---Sets DF's process-global native turbo-speed switch for the current example.
---This affects the whole simulation, not selected units. DwarfSpec restores the
---inherited switch value during cleanup, but cannot rewind gameplay that advances
---while turbo speed is enabled.
---@param enabled boolean
---@param command_options? dwarfspec.CommandOptions
---@return boolean
function DS.setTurboSpeed(enabled, command_options) end

---Selects unit-speed behavior for one example.
---Both behaviors default to false, and at least one must be true. When
---`unit_ids` is omitted, DwarfSpec snapshots the currently eligible active,
---living citizens and long-term residents when the command is called.
---@class dwarfspec.UnitSpeedOptions
---@field fast_actions? boolean Sets supported positive unit action timers to one each simulation tick. Defaults to false.
---@field teleport_jobs? boolean Moves eligible units to guarded current-job destinations each simulation tick. Defaults to false.
---@field unit_ids? integer[] Restricts activation to a nonempty list of unique stable ids for the same active, living citizen and long-term-resident population used by omitted targeting.

---Identifies one loaded-map unit coordinate.
---@class dwarfspec.UnitPosition
---@field x integer
---@field y integer
---@field z integer

---Activates per-unit action speed and/or guarded job travel for this example.
---Unlike `setGameSpeed`, this does not change the game's TPS target. Cleanup
---disables the accelerator and restores coordinates changed through the shared
---position controller, but does not reverse paths, jobs, timers, or broader
---gameplay effects.
---@param options dwarfspec.UnitSpeedOptions
---@param command_options? dwarfspec.CommandOptions
function DS.setUnitSpeed(options, command_options) end

---Moves one resolvable unit to a valid loaded-map coordinate.
---The integer id is re-resolved at use time. The first successful move owns the
---unit's original coordinate for this example; later explicit or job-travel
---moves share that baseline. Cleanup restores owned coordinates but does not
---reverse broader gameplay effects.
---@param unit_id integer
---@param position dwarfspec.UnitPosition
---@param command_options? dwarfspec.CommandOptions
function DS.setUnitPos(unit_id, position, command_options) end

---Returns the current in-year simulation tick for the loaded DF world.
---@param command_options? dwarfspec.CommandOptions
---@return integer
function DS.getTick(command_options) end

---Returns DFHack's current millisecond clock value.
---@param command_options? dwarfspec.CommandOptions
---@return integer
function DS.getTime(command_options) end

---Returns the directory name of the currently loaded save game.
---@param command_options? dwarfspec.CommandOptions
---@return string
function DS.getSaveDirectoryName(command_options) end

---Discards the loaded save and waits for the native title main menu.
---An already-visible title main menu is an idempotent no-op. The resulting
---state is not restored during example cleanup.
---@param command_options? dwarfspec.CommandOptions
---@return string|nil exited_directory
function DS.exitToMainMenu(command_options) end

---Ensures that one exact save directory is loaded.
---If another world is loaded, it is discarded without saving first. The
---requested world remains loaded for subsequent examples and is not restored
---or unloaded by example cleanup.
---@param directory_name string
---@param command_options? dwarfspec.CommandOptions
---@return string
function DS.mountSaveGame(directory_name, command_options) end

---Returns whether the current DFHack focus matches one focus path.
---@param path string
---@param command_options? dwarfspec.CommandOptions
---@return boolean
function DS.hasFocus(path, command_options) end

---Returns the map tile aligned with the selected screen origin.
---The origin defaults to `EScreenOrigin.CENTER`.
---@param origin? dwarfspec.EScreenOrigin
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.MapViewPosition
function DS.getViewPos(origin, command_options) end

---Aligns one map tile with the selected screen origin for the current example.
---The origin defaults to `EScreenOrigin.CENTER`.
---DwarfSpec automatically restores the inherited position during cleanup.
---@param position dwarfspec.MapViewPosition
---@param origin? dwarfspec.EScreenOrigin
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.MapViewPosition
function DS.setViewPos(position, origin, command_options) end

---Identifies a callable DFHack defclass table accepted by `ds.mount`.
---Runtime validation distinguishes a class from an already-created instance.
---@alias dwarfspec.ComponentClass table

---Identifies a component exported by a bed-local Lua module.
---@class dwarfspec.ModuleComponentSource
---@field kind 'module'
---@field name string
---@field export? string

---Identifies a component exported by a bed-local DFHack script module.
---@class dwarfspec.ScriptComponentSource
---@field kind 'script'
---@field name string
---@field export? string

---Selects a component source that must be resolved through a TestBed.
---@alias dwarfspec.TestBedComponentSource
---| dwarfspec.ModuleComponentSource
---| dwarfspec.ScriptComponentSource

---Mounts one owned component or complete screen.
---DwarfSpec automatically unmounts it during example cleanup.
---@overload fun(source: dwarfspec.TestBedComponentSource, options?: dwarfspec.MountOptions, testbed?: dwarfspec.TestBedConfig, command_options?: dwarfspec.CommandOptions): dwarfspec.Subject
---@param component dwarfspec.ComponentClass
---@param options? dwarfspec.MountOptions
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.Subject
function DS.mount(component, options, command_options) end

---Mounts the current native DF screen without taking ownership of it.
---The mount creates, shows, resizes, and dismisses no screen.
---DwarfSpec automatically detaches the mount during example cleanup.
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.Subject
function DS.mountNativeScreen(command_options) end

---Returns a subject for the selected current-mount root.
---With no options, a native mount returns the exact borrowed
---`viewscreen.widgets` container. Source options are accepted only by a
---borrowed native-screen mount.
---@param options? dwarfspec.RootSourceOptions
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.Subject
function DS.root(options, command_options) end

---Releases the current native attachment or mounted component.
---@param command_options? dwarfspec.CommandOptions
function DS.unmount(command_options) end

---Selects one exact path from the implicit current mount.
---On a borrowed native-screen mount without `native_root`, DwarfSpec checks
---both `viewscreen.widgets` and `df.global.game.main_interface`. Declared
---game-UI fields form a structural prefix; traversal switches permanently to
---exact widget names or zero-based indices at the first non-field segment on a
---widget container. Equal results are deduplicated and different results are
---reported as ambiguous. `native_root` bypasses this dual-root resolution.
---Component paths retain their strict direct-`subviews` behavior.
---@param control_path string|dwarfspec.NativePath
---@param options? dwarfspec.GetSourceOptions
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.Subject
function DS.get(control_path, options, command_options) end

---Returns a stable read-only diagnostic table for one live subject.
---@param view? dwarfspec.Subject Defaults to the current source root.
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.SubjectInspectState
function DS.inspect(view, command_options) end

---Searches the current mount's final rendered screen-cell buffer.
---Matching is literal and case-sensitive. Occurrences are counted
---top-to-bottom, then left-to-right. A match returns exact zero-based
---inclusive UI-grid bounds; an ordinary readable miss returns nil. The
---operation fails when the entire effective region is unreadable.
---Subject areas are spatial bounds and do not prove render ownership.
---@param query dwarfspec.TextSearchQuery
---@param search_area? dwarfspec.TextSearchArea Defaults to the current mount's search scope.
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.ScreenRect|nil
function DS.search(query, search_area, command_options) end

---Invalidates the mounted screen and waits for a completed render by default.
---Pass `{wait=false}` to return after invalidation without waiting.
---@param view? dwarfspec.Subject Defaults to the current source root.
---@param options? dwarfspec.RedrawOptions
---@param command_options? dwarfspec.CommandOptions
---@return any
function DS.redraw(view, options, command_options) end

---Captures the current implicit mount tree under one evidence name.
---Source options are accepted only by a borrowed native-screen mount.
---@param name string
---@param options? dwarfspec.CaptureViewTreeSourceOptions
---@param command_options? dwarfspec.CommandOptions
---@return table
function DS.capture_view_tree(name, options, command_options) end

---Moves the pointer by subject anchor, UI-grid cell, exact screen pixel, or
---world tile.
---Numeric calls default to `EPointerSpace.GRID`. Explicit pixel calls preserve
---the requested pixel exactly and expose its derived UI-grid cell. World-tile
---calls recenter the map view by default; pass `{recenter=false}` to require
---the tile to already be visible. DwarfSpec reads current effective renderer
---geometry for each move and restores pointer and camera state automatically
---during cleanup.
---@overload fun(x: integer, y: integer, command_options?: dwarfspec.CommandOptions): integer, integer
---@overload fun(x: integer, y: integer, space: dwarfspec.GridPointerSpace, command_options?: dwarfspec.CommandOptions): integer, integer
---@overload fun(x: integer, y: integer, space: dwarfspec.PixelPointerSpace, command_options?: dwarfspec.CommandOptions): integer, integer
---@overload fun(position: dwarfspec.MapViewPosition, space: dwarfspec.WorldTilePointerSpace, options?: dwarfspec.WorldTilePointerOptions, command_options?: dwarfspec.CommandOptions): integer, integer, integer
---@param view? dwarfspec.Subject Defaults to the current source root.
---@param anchor? dwarfspec.EPointerAnchor Subject anchors use UI-grid cells.
---@param command_options? dwarfspec.CommandOptions
---@return integer x
---@return integer y
function DS.move_pointer(view, anchor, command_options) end

---Moves the pointer over a subject or numeric coordinate and waits for render.
---Subject anchors use UI-grid cells. Numeric calls use the same coordinate
---space and return rules as `move_pointer`.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---@overload fun(x: integer, y: integer, command_options?: dwarfspec.CommandOptions): integer, integer
---@overload fun(x: integer, y: integer, space: dwarfspec.GridPointerSpace, command_options?: dwarfspec.CommandOptions): integer, integer
---@overload fun(x: integer, y: integer, space: dwarfspec.PixelPointerSpace, command_options?: dwarfspec.CommandOptions): integer, integer
---@param view? dwarfspec.Subject
---@param anchor? dwarfspec.EPointerAnchor
---@param command_options? dwarfspec.CommandOptions
---@return integer x
---@return integer y
function DS.hover(view, anchor, command_options) end

---Sends supported native input and waits for the live screen to settle.
---@param keys string|string[]|table
---@param subject? dwarfspec.Subject
---@param command_options? dwarfspec.CommandOptions
---@return integer
function DS.input(keys, subject, command_options) end

---Sends one mouse action at the current virtual pointer position.
---Physical mouse buttons default to the click input state.
---DwarfSpec automatically restores state owned by persistent `DOWN` or `UP`
---actions during cleanup.
---@param button dwarfspec.EMouseButton
---@param action? dwarfspec.EInputState
---@param command_options? dwarfspec.CommandOptions
---@return integer
function DS.mouseInput(button, action, command_options) end

---Sends discrete wheel inputs at the current pointer or over a subject.
---Steps are inputs, not pixels or guaranteed scroll rows; only the final
---render is awaited.
---@param options dwarfspec.MouseWheelOptions
---@param subject? dwarfspec.Subject
---@param command_options? dwarfspec.CommandOptions
---@return integer
function DS.mouseWheel(options, subject, command_options) end

---Clicks a view with a supported native mouse button and waits for render.
---DwarfSpec automatically restores inherited pointer state during cleanup.
---It does not reverse game or UI effects caused by the click.
---@param view dwarfspec.Subject
---@param button? dwarfspec.MouseButton
---@param command_options? dwarfspec.CommandOptions
---@return integer
function DS.click(view, button, command_options) end

---Types ASCII text through DFHack's supported string keycodes.
---@param text string
---@param subject? dwarfspec.Subject
---@param command_options? dwarfspec.CommandOptions
---@return integer
function DS.type(text, subject, command_options) end

---Changes the current mounted component viewport and waits for its render.
---The viewport remains mount-scoped and ends with DwarfSpec's automatic
---unmount cleanup.
---@param width integer
---@param height integer
---@param command_options? dwarfspec.CommandOptions
---@return any
function DS.viewport(width, height, command_options) end

---Captures and retains a bounded plain screen-cell buffer.
---@param name string
---@param options? dwarfspec.ScreenCaptureOptions
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.ScreenCapture
function DS.capture_screen(name, options, command_options) end

---Stages a real overlay source for a registration integration test.
---DwarfSpec automatically disables its overlays, restores configuration, and
---removes its unchanged staged script during lifecycle cleanup.
---@param source_path string
---@param logical_name string
---@param command_options? dwarfspec.CommandOptions
---@return table
function DS.stage_overlay_registration(source_path, logical_name, command_options) end

---Returns the current run handle through the verified query contract.
---@param command_options? dwarfspec.CommandOptions
---@return table
function DS.current_run(command_options) end

---Registers a receipt-backed cleanup transaction for the current owner.
---@param registration dwarfspec.CleanupRegistration
---@param command_options? dwarfspec.CommandOptions
---@return dwarfspec.CleanupTransaction
function DS.registerCleanup(registration, command_options) end

---@diagnostic disable-next-line: lowercase-global
---@type dwarfspec.DS
ds = ds

return DS
