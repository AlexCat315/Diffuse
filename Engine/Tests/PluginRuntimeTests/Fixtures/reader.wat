(component
  (core module $guest
    (memory (export "memory") 1)
    (global $next (mut i32) (i32.const 4096))
    (data (i32.const 128) "true")
    (data (i32.const 144) "false")
    (func $realloc (export "realloc")
      (param $old i32) (param $old-size i32)
      (param $align i32) (param $new-size i32) (result i32)
      (local $result i32)
      local.get $new-size
      i32.eqz
      if (result i32)
        i32.const 0
      else
        global.get $next
        local.set $result
        global.get $next
        local.get $new-size
        i32.add
        global.set $next
        local.get $result
      end)
    (func (export "inspect") (param $enabled i32) (result i32)
      i32.const 0
      local.get $enabled
      if (result i32)
        i32.const 128
      else
        i32.const 144
      end
      i32.store
      i32.const 4
      local.get $enabled
      if (result i32)
        i32.const 4
      else
        i32.const 5
      end
      i32.store
      i32.const 0))
  (core instance $guest (instantiate $guest))
  (type $inspect-input (record (field "enabled" bool)))
  (type $inspect-func (func
    (param "input" $inspect-input) (result string)))
  (func $inspect (type $inspect-func)
    (canon lift (core func $guest "inspect")
      (memory $guest "memory")
      (realloc (func $guest "realloc"))))
  (component $capabilities-component
    (type $local-input (record (field "enabled" bool)))
    (import "import-type-inspect-input"
      (type $import-input (eq $local-input)))
    (type $import-func (func
      (param "input" $import-input) (result string)))
    (import "import-func-inspect" (func $implementation
      (type $import-func)))
    (type $export-input (record (field "enabled" bool)))
    (export $public-input "inspect-input" (type $export-input))
    (type $export-func (func
      (param "input" $public-input) (result string)))
    (export "inspect" (func $implementation)
      (func (type $export-func))))
  (instance $capabilities
    (instantiate $capabilities-component
      (with "import-func-inspect" (func $inspect))
      (with "import-type-inspect-input" (type $inspect-input))))
  (export (interface "safe:reader/capabilities")
    (instance $capabilities))
)
