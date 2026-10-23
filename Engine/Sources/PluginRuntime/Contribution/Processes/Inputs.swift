/// `record { request: string, stdout: string }`: the step request as JSON and
/// a window of the last command's output, the input of every entry point the
/// step protocol drives.
let stepInputType = WITValueType.record([WITRecordField(name: "request", type: .string),
                                         WITRecordField(name: "stdout", type: .string)])

/// `record { text: string }`: the whole document handed to a format entry point.
let documentFormatInputType = WITValueType.record([WITRecordField(name: "text", type: .string)])

