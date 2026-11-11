# Graph assistant

Design and working notes for the AI graph assistant (PLAN.md Phase 8). This file is allowed to change faster than ARCHITECTURE.md. Architectural rulings go in DECISIONS.md (211-214).

Status: **steps A and most of B built; step C slices 1 and 2 (`NodeGraphAI` tools, endpoints, staged generation with a repair loop) built, none of it tried on a model.** Package names below are proposals.

## Goal

An assistant inside the editor that can generate graphs, edit them, find logical issues, explain the graph and its results, and suggest improvements. Apple's models come first (how far do they go?), but nothing may depend on them: the user picks the model.

## Principles

1. **Deterministic first, model second.** Analysis (lints, tracing, run values) is plain Swift and testable. The model chooses, phrases and ranks. A finding from a lint is a fact; one from a model is a suggestion, and the UI says which.
2. **Proposals, never edits.** No tool changes the document. Tools return a pending change set (a `GraphCommand` batch plus a description) that the user previews and accepts as one undo step (decision 211).
3. **Model-agnostic.** All assistant code talks to `LanguageModelSession`. Apple on-device, Apple Private Cloud Compute and Claude are interchangeable `LanguageModel`s (decision 212).
4. **Small-context safe.** The on-device model has 4K tokens. Everything the model sees goes through the graph digest, and every feature has a staged, small-prompt path.

## Packages (proposed)

| Package | Content | Depends on | Builds on Linux |
|---|---|---|---|
| `NodeGraphAssistant` | Graph digest, `GraphSpec` and compiler, lints, tracing, assistant tool *logic*, `PendingChange` | Core | Yes |
| `NodeGraphAI` | FoundationModels glue: `Tool` wrappers, schema builders, sessions, providers, routing, Keychain | Assistant, FoundationModels | No (Apple only, `#if canImport(FoundationModels)`) |
| `NodeGraphUI` | Prompt overlay, chat panel, preview of a pending change, model picker | Assistant, AI | No |

Core gets no AI knowledge. If a lint needs a Core hook (for example a richer `Diagnostic`), add it to Core with its own test.

## Model-independent building blocks (steps A and B)

### Graph digest
A compact, stable text/JSON form of a graph, selection or neighborhood: aliases instead of UUIDs, type ids, only the properties that differ from defaults, links as `n1.out -> n2.a`, no layout. It has size tiers (4K-safe and larger). Everything else reuses it: prompts, tool results, explanations, diffs.

### `GraphSpec` and compiler
The model's output format for generation: nodes (alias, type, properties), links, groups. `GraphSpecCompiler` resolves it against a `NodeRegistry` and returns a `GraphFragment` (laid out with `Arrangement.layered`) or a list of errors, then `pasteCommand` produces the command. It is also a scriptable text format for building graphs without any model. Errors are specific so they can be sent back to a model for repair.

### Lints
Deterministic checks that produce `Diagnostic`s with a suggested fix as a command where one exists:
- required input unconnected; output nobody uses; unreachable or dead branches
- muted or bypassed node on the only path to an output
- feedback loop with no delay node (beyond what the validator already rejects)
- constant-foldable subgraph; duplicated subgraphs; identical sibling nodes
- type smells (a number feeding a port that is conceptually an angle or a duration, where packs mark it)
- property outside a sensible range

Packs may register extra lints.

### Tools and pending changes
Tool logic is plain Swift, wrapped for FoundationModels later.

| Kind | Tools |
|---|---|
| Read-only | `searchNodes`, `describeNode`, `getSelection`, `getNeighborhood(node, depth)`, `lint`, `getDiagnostics`, `getRunValues(port)`, `traceUpstream(port)` |
| Run | `runGraph(overrides)`, `compareRuns` |
| Propose | `proposeEdit(commands)`, `proposeGeneration(spec)` |

`PendingChange` carries the batch, a description, the lint/validation results of the *result* graph, and optionally a before/after run comparison. The editor previews it as a ghost overlay with Accept and Reject.

## Models and providers

| Provider | Context | Reasoning | Network | Limits | Setup |
|---|---|---|---|---|---|
| Apple on-device (`SystemLanguageModel`) | 4K | No | No | None | None. Default |
| Apple Private Cloud Compute (`PrivateCloudComputeLanguageModel`) | 32K | Yes | Yes | Per-user daily quota | Managed entitlement from Apple (not requested yet), iOS/macOS 27+ |
| Claude (custom `LanguageModel` and executor) | Large | Yes | Yes | The user's own API key and billing | User enters a key |

- **Any OpenAI-compatible server** (OpenAI, OpenRouter, Ollama, LM Studio, llama.cpp, vLLM) is one more kind of `ModelEndpoint` (decision 227), with its own address, model name, context size and key. A server on this machine stays on the device; one elsewhere does not, and the privacy prompt follows that. Tool calling varies by model, so the executor declares what each can do.
- PCC is **not an automatic fallback**: a session uses the model it was created with. Switching is one line, and the same tools, instructions and schemas carry over. Fallback is our own routing.
- PCC `availability` leaves out the network. Try the request and handle `.networkFailure`, `.quotaLimitReached` (reset date, upgrade suggestion) and `.serviceUnavailable`.
- The Claude executor is ours to write: transcript to messages, tool calls, `GenerationSchema` (which is `Codable`) to JSON schema, streaming events back through the executor channel, and a declared `capabilities` set so the framework refuses what the model can't do. It uses `URLSession`, no SDK (decision 214).
- **Key storage:** Keychain, per device. iCloud Keychain sync is a later option, decided after the server work (decision 214). It would spare users separate credentials.
- **Routing (opt-in "Auto"):** small local tasks go on-device; work that exceeds the on-device budget goes to the user's chosen larger model; retry on `contextSizeExceeded`, network failure or quota. The UI shows which model answered.
- **Privacy:** on-device is the default. Choosing a cloud model shows what will be sent (digest, run values). Graph data can be sensitive, and Claude is a third party, so sending is always an explicit choice.
- **Apple eval:** start features on-device, measure with the Evaluations framework, and move to PCC only where quality needs it.

## Generation strategy for small models

Staged, with constraints built from the registry through `DynamicGenerationSchema`:
1. Pick nodes: aliases and types as an `anyOf` of registered ids described by `help` text. Use the `searchNodes` tool when the registry is too big for the prompt (tool mode `.required` on the first turn).
2. Set properties: one schema per chosen node from its `PropertyDefinition`s.
3. Wire links: a schema offering only real, type-compatible, correctly directed `(alias, port)` pairs from stage 1.

Then compile, validate, and on errors feed the messages back to the same session (at most 2 or 3 repairs). Whatever is still invalid is dropped and reported. Larger models can skip stages. Packs should ship `help` text and 2 or 3 small example specs, since examples help small models more than instructions.

## Feature backlog

Core five: generate, edit, find logical issues, explain, suggest.

Also wanted, roughly by value:
- Explain *why this value is X* (trace upstream through last run values). Highest value for the least model risk.
- Chat with selection and run context; ask about the node library with an insert action; teaching mode (step through in execution order).
- Autocomplete after adding a node; property fill from intent; auto-naming of groups, ports, variables, subgraphs; documentation for subgraphs.
- Tests and verification: generate deterministic test cases; what-if runs; invariant checks by sweeping inputs; before/after run comparison on every proposed edit.
- Runtime: explain failed runs from `ExecutionEvent`s; performance diagnosis from per-node durations.
- Parameter tuning against a stated objective (Swift drives run/score/adjust, the model proposes ranges). Needs a clear stop condition.
- Import from a formula, pseudo-code or description; domain assistants through pack extensions (vocabulary, tools, examples, lints).
- App Intents and Shortcuts ("generate a graph that...", "run graph X"); voice input on iPad.

## Evaluation

A set of golden tasks (prompt or graph in, expected properties of the result out) for generate, explain and find-the-bug, run by hand against each provider. Compiler and lint tests run in CI; model quality is judged by the eval, not by CI. Record results per provider and per prompt version here.

## Open questions

- Request the PCC managed entitlement? Not decided; plan so it can be added later (one line).
- Where do domain-specific assistant extensions register: on `NodePack` or a separate protocol?
- Digest format details (JSON or a terser text form) once measured against the 4K budget.
- Whether the Claude executor warrants its own package so other projects can use it.
