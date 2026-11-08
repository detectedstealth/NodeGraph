# litegraph.js feature audit

litegraph.js is a feature reference, not a compatibility target (DECISIONS.md). This lists its features and what we do about each.

Sources: litegraph.js `README.md`, `guides/README.md`, `src/litegraph.js` (read up to character 450k of 493k, so the tail of the canvas code is not covered) and node files `base`, `math`, `events`, `logic`, `interface`, `strings`. The node files `audio`, `geometry`, `glfx`, `glshaders`, `gltextures`, `graphics`, `input`, `math3d` (names only), `midi`, `network`, `others` were not read; they are web or media specific.

Status: **Done** (implemented), **Partial**, **Gap** (in scope, not built), **Deferred** (wanted, later phase), **Out** (out of scope, reason given).

"Done" and "Gap" were judged from the plan, the decisions log and a code search, not by running the app. Items marked `?` need a check before work starts.

## 1. Node features

| litegraph feature | Status | Notes |
|---|---|---|
| Register node types, categories, auto-sorted palette | Done | `NodeRegistry`, packs, `NodeCatalog` |
| Typed inputs and outputs, wildcard `*`, multi-type slots | Done | `PortType`, `TypeRegistry`; `.any` |
| Per-node properties, `onPropertyChanged`, property info (min/max/enum) | Done | `Property` schema; inspector |
| Inputs take one link, outputs many | Done | `ConnectionValidator` |
| Event slots (ACTION in, EVENT out) | Done | trigger ports, separate from data |
| Node modes: always, on event, never, on trigger | Done | `NodeMode`: always, never, muted, bypassed, on |
| Wrap a function as a node | Gap | A small builder in Core (`NodeDefinition.function(...)`) would cut pack boilerplate. Check how packs are written first |
| Dynamic ports, `onGetInputs`/`onGetOutputs` optional slots, add optional from menu | Partial | Declarative variadic ports done; "Add optional input" menu entry `?` |
| `onConnectInput` veto, `onConnectionsChange` | Partial | Pluggable `ConnectionValidator` per domain; per-node closure hooks decided against (decision 91) |
| Execution priority (`priority`) | Gap | Order is topological then stable. A per-definition priority for tie-breaks is cheap |
| Node colour, title, collapse, pin, resize | Done | inspector and menus |
| Node shapes (box, round, card) | Done | `NodeShape` on node and definition (decision 185) |
| Title modes (normal, none, transparent, autohide) | Done | `NodeTitleMode` (`none` is `hidden`, decision 186); drawing only (decision 187) |
| Custom colour per slot (`color_on`, `color_off`), slot shapes | Partial | Colour by type via theme. Slot shapes done (`PortShape`: circle, square, diamond, arrow, grid). Per-slot colour override Gap |
| Vertical slot layout (`horizontal`, slot `dir`) | Gap | Needed for flow-chart style graphs. Touches `NodeLayout`, hit testing and links. Medium size |
| Widgets: number, slider, combo, text, toggle, button | Done | plus multiline, color |
| Widget bound to a property, options (min, max, step, precision, values) | Done | |
| Widgets before slots (`widgets_up`), `widgets_start_y` | Out | Layout is ours; one order is enough |
| Widget value serialization (`serialize_widgets`) | Done | widgets edit properties, which serialize |
| Widget converted to an input slot | Gap | ComfyUI-style, not litegraph core, but useful: a property that can also be wired. Check whether property-to-port exists in Core |
| Custom drawing (`onDrawBackground`, `onDrawForeground`) | Done | `NodeContentDrawing` |
| Node mouse hooks (`onMouseDown` etc.) | Partial | Custom widgets cover most; no raw pointer hook into the content area |
| `onDblClick`, `onSelected`, `onDeselected` hooks | Out | Observe model selection instead |
| `onDropItem`, `onDropFile` | Deferred | Needs SwiftUI drop destinations; asset handles arrive with Phase 7 video |
| `onKey` per node | Out | Command map is global |
| `onExecute`, `onAction` | Done | async `execute` |
| `onSerialize`/`onConfigure` extra data | Done | properties and `JSONValue` extras |
| `getExtraMenuOptions` | Gap | Let a definition or pack add entries to the node menu |
| `onAdded`, `onRemoved`, `onStart`, `onStop` | Partial | Execution events exist; definition lifecycle hooks Gap, low priority |
| Node clone | Done | duplicate, copy/paste |
| `flags.allow_interaction` per node | Gap | Per-node lock. Pin covers moving only |
| Mode colouring of the title box, trigger-lit boxes | Partial | Execution overlay tints; mode colouring `?` |
| Node help text / tooltips | Partial | `NodeDefinition.help` in the palette and inspector (decision 198); no hover tooltip on the canvas |

## 2. Link and graph features

| litegraph feature | Status | Notes |
|---|---|---|
| Spline, linear, straight links | Done | `LinkStyle` |
| Link arrows, link shadows | Gap | Cosmetic. Arrow at the midpoint is cheap |
| Link centre marker with menu (Add Node, Delete) | Partial | Waypoints and link menu done; "Add Node into link" `?` |
| Link tooltip showing the value passing | Done | label at the link midpoint on hover or selection (decision 179) |
| Link colour by type | Done `?` | |
| Reroute | Done | waypoints and `util.reroute` |
| Groups: add, colour, move with contents, resize, align | Done | |
| Subgraphs, graph inputs and outputs, edit interface | Done | Phase 3 and 4 |
| Global graph variables (`vars`, `Globals`) | Done | read-only parameters with run overrides (decisions 189-192); writing from the graph (`data_store`) is not built; state exists now (decision 193) but variables stay read-only; variables can be renamed and readers pick them from a list (decision 201) |
| Graph `config` and `extra` bag | Done | `GraphDocument.metadata`, a free-form `[String: GraphValue]` bag, already existed |
| Execution order display (`render_execution_order`) | Gap | Cheap debug overlay from `ExecutionPlan` |
| Start, stop, step, fixed time step, elapsed time | Done | `GraphRunner` modes |
| Error catching per node | Done | |
| Placeholder for unknown node types | Done | |
| Hot-replace node versions (`checkNodeTypes`) | Partial | Migration chain for documents; per-node-type versioning `?` |
| `MAX_NUMBER_OF_NODES` | Out | Tested at 10k |
| Graph hooks (`onNodeAdded`, `onConnectionChange`, before/after change) | Done | change stream |
| `beforeChange`/`afterChange` undo grouping | Done | command batches |
| Arrange (auto layout, horizontal/vertical) | Gap | Align and distribute done; automatic layered layout is not. Worth building (layered, by `ExecutionPlan` depth) |
| Trigger and event propagation | Done | |
| Save and load | Done | native JSON (not litegraph's format) |
| Load from URL or file | Deferred | Phase 6 stores and document app |

## 3. Canvas and interaction

| litegraph feature | Status | Notes |
|---|---|---|
| Pan, zoom, wheel zoom, middle-drag pan | Done | |
| Space-drag to pan | `?` | Check key map; add if missing |
| Rubber-band selection, shift/ctrl multi-select, select all | Done | |
| Shift-drag to move, alt-drag to clone | Partial | Duplicate command exists; alt-drag clone `?` |
| Ctrl+C / V / X, paste keeping connections (Ctrl+Shift+V) | Done | `GraphFragment`; Command-Shift-V keeps input links to unselected nodes (decision 196) |
| Delete with auto-bridge of first input/output | Done | Shift-Delete or the node menu (decision 195) |
| Double-click empty canvas for search | Done | |
| Search box with type filters, keyboard navigation | Partial | Search and keyboard done; filter by the slot type when released from a link `?` |
| Release link on empty space shows menu | Done | opens add-node with the port as filter |
| Middle-click a slot adds a default node | Partial | Per-type defaults and a port context menu item (decision 197); no middle-click gesture |
| Click-to-break link, shift-click output to move links | Done | reconnect and shift-drag move |
| Incompatible slots dim while dragging a link | `?` | |
| Collapse by title click | Partial | Collapse command exists; click gesture `?` |
| Context menus: node, canvas, slot, link | Done | node, canvas and link; slot menu is the connection chooser |
| Menu: Align, Collapse, Pin, Mode, Colors, Properties | Done | |
| Menu: Shapes | Done | Shape and Title Bar submenus |
| Node panel (title, mode, colour, properties, delete) | Done | inspector |
| Graph options panel (render mode, shadows, etc.) | Partial | inspector graph section; canvas display options (grid, link style, shadows) as settings `?` |
| Prompt dialog, property value editors | Done | widget editor overlays |
| Subgraph input/output dialogs | Done | interface editor |
| Live mode (hide graph, show node UI) | Deferred | Not a plain editor feature; a "presentation mode" showing only widgets and custom drawing suits the dashboards of the robotics and video proofs. Phase 7 |
| Read-only / `allow_interaction` for the canvas | Done | `GraphEditorModel.isEditable` (decision 175): blocks every edit in the model and the UI, keeps selecting, panning, zooming, copying and subgraph navigation |
| Low quality rendering below zoom 0.6 | Done | level of detail |
| Viewport culling | Done | |
| Theme: colours, background image, shadows | Partial | `GraphTheme`; background image and shadows Gap, cosmetic |
| `show_info` stats overlay | Gap | Debug overlay (nodes, visible, FPS). Cheap |
| Canvas render to image | Gap | Export the graph as PNG/PDF. `ImageRenderer` already used in benchmarks |
| Mini-map | Done | litegraph has none |
| Undo/redo | Done | litegraph has no stack on its own |
| Accessibility | Done | beyond litegraph |
| Drag-drop file creates a node | Deferred | with `onDropFile` |
| Clipboard in localStorage | Out | system pasteboard `GraphClipboard` |

## 4. Built-in node families

Our packs hold 76 node types (decision list in PLAN). Comparison with litegraph's families:

| litegraph family | Status | Notes |
|---|---|---|
| `basic/const`, `boolean`, `string` | Done | `util.number`, `util.bool`, `util.string` |
| `basic/watch`, `console`, `alert` | Done | `util.watch` (shown with `NodeContentDrawing.readout`) and `util.log` (to swift-log; no console view yet). Alert Out |
| `basic/time` | Done | `util.time`: elapsed, delta, tick |
| `basic/variable`, `data_store` | Partial | `util.variable` reads. Writing (`data_store`) is not built (decision 194) |
| `basic/object`, `object_property`, `set_object`, `merge_objects`, `object_keys`, `jsonparse`, `data` | Done | `DataPack`: get, set, merge, keys, parse and write JSON (decision 182). `data` (data_store) waits on graph variables |
| `basic/array`, `set_array`, `array[]`, `table[][]` | Done | make, get, set, length, append, slice. `table[][]` Out |
| `basic/cast`, `math/converter`, `to_number` | Done | `convert.toNumber`, `toBool`, `toInt`; runtime port conversion is still open (decision 61) |
| `basic/CompareValues`, `string/compare` | Done | `logic.compare` |
| `basic/script`, `math/formula` | Out | No embedded script runtime (non-goal: no JS). An expression-only node (`math.expression`) with a small parser is a reasonable Gap, with no `eval` |
| `basic/file`, `download`, `network/*` | Deferred | Needs asset and IO policy; Phase 6/7 |
| `graph/subgraph`, `graph/input`, `graph/output` | Done | |
| `math/*` arithmetic: operation, abs, floor, scale, clamp, lerp | Done | |
| `math/range` (remap), `smoothstep`, `frac`, `tendTo`, `average`, `accumulate` | Partial | All done; average, accumulate and tendTo use per-node state (decisions 193-194) |
| `math/rand`, `noise`, `spikes` | Partial | `math.random`, seeded and repeatable (decision 181). Noise and spikes Gap |
| `math/trigonometry` | Done | sin, cos, tan, asin, acos, atan, atan2 |
| `math/compare`, `condition`, `branch`, `gate` | Done | `logic.compare`, `logic.select`, `flow.gate` |
| `math3d/vec2/3/4` split and combine | Gap | Needs vector types registered by a pack. Vec2/Vec3 for robotics and video |
| `logic/AND`, `OR`, `NOT`, `selector`, `IF`, `CompareBool` | Done | plus xor |
| `logic/sequence` (split and index) | Gap | with string split |
| `events/*`: log, trigger, sequence, waitAll, stepper, filter, branch, counter, delay, timer, semaphore, once | Partial | `flow.delay`, `every`, `gate`, `both`, bool/trigger converters, `util.log`. Filter is `gate`; sequence is meaningless within a pass. `flow.counter`, `once` and `latch` (stands in for semaphore) use node state (decision 194). Not built: stepper, and a waitAll that remembers |
| `string/*`: concat, contains, upper, split, toFixed, toString, toTable | Done | concat, contains, upper/lower, join, replace, trim, length, format (to string), split, `string.toFixed`. `toTable` Out |
| `widget/*` (button, toggle, number, combo, knob, sliders, progress, text, panel) | Partial | Our widgets live inside nodes and edit properties. Gap: standalone output-widget nodes only where useful: knob, progress, text display, panel (a note covers panel) |
| `audio/*`, `midi/*` | Out | Web Audio. A media pack belongs to the video proof |
| `glfx/*`, `glshaders/*`, `gltextures/*`, `graphics/*`, `geometry/*` | Out | WebGL. Video/image effects come in Phase 7 on Apple frameworks |
| `input/*` (gamepad, keyboard) | Deferred | `GameController` input pack for robotics, Phase 7 |

## 5. Out of scope, on purpose

- litegraph JSON format, `LiteGraph.*` constants and class names, `registerNodeType` string API.
- Embedded JavaScript (`basic/script`, `math/formula` with `eval`), Web Audio, WebGL, DOM events, localStorage, browser file drop.
- `onDropItem` (DOM items), `redraw_on_mouse`, `clip_area` and other canvas-2D implementation flags.

## 6. Gaps worth building, ranked

Ranking is by value to the editor and to the Phase 7 domains, then by cost.

1. **Read-only canvas mode** (`isEditable`): small; needed by any viewer, the server preview and dashboards.
2. **Watch, time and log nodes**, plus **last run values on links** (link tooltip): the core debugging loop. Needs run values exposed from `GraphRunner` events.
3. **Core node pack gaps**: arrays and objects, remap/smoothstep/frac, full trigonometry, seeded random, split/toString, event nodes (counter, sequence, waitAll, once, filter), converters.
4. **Node shapes and title modes**, slot shapes: cosmetic but expected, one theme-driven change.
5. **Graph variables and `extra`/`config` metadata** on the document: needs a decision, touches the file format and migration.
6. **Delete with bridge**, **paste keeping connections**, **default node per slot type**, **node help text**: small editor aids.
7. **Auto-arrange** (layered layout).
8. **Vertical slot layout**: medium, risky for hit testing, do only if a domain needs it.
9. **Vector types** (vec2/3/4 plus split/combine): with the robotics pack.
10. Display extras: execution order overlay, stats overlay, export to image, link arrows.

Items marked `?` above are to be confirmed by reading the code when the item is picked up.
