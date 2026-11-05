extension NodeDefinition {
    /// The outputs of a bypassed node: its inputs passed through to outputs.
    ///
    /// Each data output, in order, takes the value of the first not-yet-used data input that has
    /// a value and a matching type (equal, or either side `any`). Trigger outputs fire when the
    /// trigger input at the same position fired.
    ///
    /// - Parameters:
    ///   - inputs: Effective input values, including port defaults.
    ///   - triggered: Trigger inputs that fired.
    public func bypassedOutputs(inputs: [PortID: GraphValue], triggered: Set<PortID>) -> NodeOutputs {
        var values: [PortID: GraphValue] = [:]
        var used = Set<PortID>()
        let dataInputs = self.inputs.filter { $0.kind == .data }
        for output in outputs where output.kind == .data {
            guard let input = dataInputs.first(where: {
                !used.contains($0.id) && inputs[$0.id] != nil && Self.typesMatch($0.type, output.type)
            }) else { continue }
            used.insert(input.id)
            values[output.id] = inputs[input.id]
        }

        let triggerInputs = self.inputs.filter { $0.kind == .trigger }
        let triggerOutputs = outputs.filter { $0.kind == .trigger }
        var fired = Set<PortID>()
        for (input, output) in zip(triggerInputs, triggerOutputs) where triggered.contains(input.id) {
            fired.insert(output.id)
        }
        return NodeOutputs(values, triggers: fired)
    }

    private static func typesMatch(_ a: PortType, _ b: PortType) -> Bool {
        a == b || a == .any || b == .any
    }
}
