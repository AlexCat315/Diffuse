(component
  (type $loop-input (record (field "enabled" bool)))
  (core module $guest
    (memory (export "memory") 1)
    (global $next (mut i32) (i32.const 4096))
    (func (export "realloc")
      (param i32 i32 i32 i32) (result i32)
      global.get $next)
    (func (export "loop") (param i32) (result i32)
      (loop $forever
        br $forever)
      unreachable)
  )
  (core instance $guest (instantiate $guest))
  (type $loop-func (func
    (param "input" $loop-input) (result string)))
  (func $loop (type $loop-func)
    (canon lift (core func $guest "loop")
      (memory $guest "memory")
      (realloc (func $guest "realloc"))))
  (component $capabilities-component
    (type $local-input (record (field "enabled" bool)))
    (import "import-type-loop-input"
      (type $import-input (eq $local-input)))
    (type $import-func (func
      (param "input" $import-input) (result string)))
    (import "import-func-loop" (func $implementation
      (type $import-func)))
    (type $export-input (record (field "enabled" bool)))
    (export $public-input "loop-input" (type $export-input))
    (type $export-func (func
      (param "input" $public-input) (result string)))
    (export "loop" (func $implementation)
      (func (type $export-func))))
  (instance $capabilities
    (instantiate $capabilities-component
      (with "import-func-loop" (func $loop))
      (with "import-type-loop-input" (type $loop-input))))
  (export (interface "safe:reader/capabilities")
    (instance $capabilities))
)
