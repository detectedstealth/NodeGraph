import NodeGraphCore

/// Help text for the built-in nodes, shown in the add-node palette and the inspector.
///
/// Kept in one table rather than beside each definition so the wording can be read and edited
/// together. Every pack applies the entries for its own types when it registers.
enum NodeHelp {
    static let text: [NodeTypeID: String] = [
        // Math
        "math.add": "Adds A and B.",
        "math.subtract": "Subtracts B from A.",
        "math.multiply": "Multiplies A by B.",
        "math.divide": "Divides A by B. Fails when B is zero.",
        "math.modulo": "The remainder of A divided by B. Fails when B is zero.",
        "math.power": "A raised to the power B.",
        "math.min": "The smaller of A and B.",
        "math.max": "The larger of A and B.",
        "math.negate": "Flips the sign of the value.",
        "math.abs": "The value without its sign.",
        "math.floor": "Rounds down to a whole number.",
        "math.ceil": "Rounds up to a whole number.",
        "math.round": "Rounds to the nearest whole number; halves round away from zero.",
        "math.sqrt": "The square root. Fails for a negative value.",
        "math.sin": "The sine of an angle in radians.",
        "math.cos": "The cosine of an angle in radians.",
        "math.tan": "The tangent of an angle in radians.",
        "math.asin": "The angle in radians whose sine is the value, from -1 to 1.",
        "math.acos": "The angle in radians whose cosine is the value, from -1 to 1.",
        "math.atan": "The angle in radians whose tangent is the value.",
        "math.atan2": "The angle in radians of the point (x, y), from -pi to pi.",
        "math.frac": "The part after the decimal point, from 0 up to 1.",
        "math.sum": "Adds any number of inputs. A free input always follows the last linked one.",
        "math.clamp": "Keeps the value between a minimum and a maximum.",
        "math.remap": "Maps a value from one range onto another.",
        "math.smoothstep": "0 below the first edge, 1 above the second, and an S-shaped ease between.",
        "math.random": "A number from min up to max that depends on the seed and the pass, so a run repeats exactly.",
        "math.lerp": "Blends from A to B by the amount T.",
        "math.accumulate": "Adds its value to a running total every pass. Reset sets the total back to zero.",
        "math.average": "The mean of the latest values, over a window of the given size.",
        "math.tendTo": "Moves toward the target by a fraction of the remaining distance each pass, starting from zero.",
        // Logic
        "logic.and": "True when both inputs are true.",
        "logic.or": "True when either input is true.",
        "logic.xor": "True when exactly one input is true.",
        "logic.not": "Flips true and false.",
        "logic.compare": "Compares A with B using the chosen operator.",
        "logic.select": "Passes one of two values, depending on a condition.",
        // Flow
        "flow.delay": "Passes its input through; what it outputs reaches nodes after it one pass later, so it can close a loop.",
        "flow.every": "Fires its trigger every N passes, starting with the first.",
        "flow.gate": "Passes a trigger on only while Open is true.",
        "flow.both": "Fires when both triggers fire in the same pass.",
        "flow.triggerToBool": "True in a pass where the trigger fired.",
        "flow.boolToTrigger": "Fires when its input is true.",
        "flow.counter": "Counts events: increment, decrement and reset, from a start value.",
        "flow.once": "Passes the first event and swallows the rest until it is reset.",
        "flow.latch": "Set turns it on, reset turns it off, and it stays that way between events. Reset wins if both fire.",
        // Strings
        "string.split": "Splits text into an array at a separator.",
        "string.toFixed": "Writes a number as text with a fixed count of decimal places.",
        "string.join": "Joins an array of values into text with a separator.",
        "string.length": "The number of characters in the text.",
        "string.contains": "True when the text contains the search text.",
        "string.format": "Turns any value into text.",
        "string.parseNumber": "Reads text as a number. Fails if it is not one.",
        "string.concat": "Joins two texts end to end.",
        "string.replace": "Replaces every occurrence of the search text. Fails if the search text is empty.",
        "string.uppercase": "The text in capitals.",
        "string.lowercase": "The text in lowercase.",
        "string.trim": "Removes spaces and line breaks from both ends of the text.",
        // Data
        "array.make": "Builds an array from any number of inputs.",
        "array.length": "The number of items in an array.",
        "array.get": "The item at an index. Fails when the index is outside the array.",
        "array.set": "A copy of the array with one item replaced.",
        "array.append": "A copy of the array with an item added at the end.",
        "array.slice": "A part of an array, from a start index for a count of items. Out of range values are clamped.",
        "object.get": "The value of a field. Found is false, and Value is left empty, when the field is missing.",
        "object.set": "A copy of the object with one field set.",
        "object.merge": "Combines two objects; fields of the second win.",
        "object.keys": "The names of an object's fields, as an array.",
        "object.parseJson": "Reads JSON text into values.",
        "object.toJson": "Writes values as JSON text. Colors, matrices and data have no JSON form.",
        "convert.toNumber": "Reads a value as a number.",
        "convert.toBool": "Reads a value as true or false.",
        "convert.toInt": "Reads a value as a whole number.",
        // Utility
        "util.number": "A fixed number.",
        "util.bool": "A fixed true or false.",
        "util.string": "A fixed piece of text.",
        "util.reroute": "A point to bend a link around; passes its input through unchanged.",
        "util.watch": "Shows the value it receives, and passes it on.",
        "util.variable": "Reads a graph variable by name: its declared value, or the run's override.",
        "util.time": "Where the run is in time: seconds elapsed, seconds since the last pass, and the pass number.",
        "util.log": "Writes its input to the log every pass, then passes it on.",
        "util.note": "A note for the reader. It does nothing when the graph runs.",
    ]

    /// Sets the help text on every type in `nodes` that has an entry.
    static func apply(to nodes: inout NodeRegistry) {
        for definition in nodes.registeredDefinitions {
            if definition.help == nil, let help = text[definition.typeID] {
                nodes.setHelp(help, for: definition.typeID)
            }
        }
    }
}
